# Developer VPN (proposal)

Developers want to reach private things in the dev VPC from their laptop: a Postgres database, a Valkey cache, an internal service. Today nothing in the catalog gives them a way in. This proposal adds one, and asks how Massdriver's access policies (ABAC) should decide who gets it.

## The flow

1. A developer joins a team group. The sandbox-on-join automation forks `sandboxes-template` into an environment of their own and copies its environment defaults.
2. The template's defaults include the AWS credential and the dev VPC (`platform-dev-network.network`), so the new sandbox already has a network.
3. The developer adds **Developer VPN** to their sandbox and deploys it. It connects to the VPC through the default, so there is nothing to wire.
4. The deployment makes a server and a key pair for the laptop, and outputs a `massdriver-wireguard-tunnel` resource.
5. The developer downloads `wg0.conf` from that resource and imports it into the WireGuard app.
6. When they leave the team, the automation decommissions the sandbox. The server and keys are deleted, so the old `wg0.conf` stops working.

Revoking access is the same thing as removing someone from the team. There is no separate list of certificates to keep up to date.

## Options

Prices are us-east-1, for a developer connected about 8 hours a day, 22 days a month.

| | AWS Client VPN (certificates) | WireGuard server per sandbox | One shared WireGuard server | SSM port forwarding |
|---|---|---|---|---|
| Fixed cost | ~$73/month per subnet the endpoint is attached to | none | ~$7/month | none, or ~$22/month per AZ for SSM endpoints if private subnets have no internet route |
| Per developer | ~$9/month connected time | ~$7/month (t4g.nano + public IP) | $0 | $0 |
| 10 developers | ~$160/month | ~$70/month | ~$7/month | ~$0–22/month |
| Issuing access | Sign a client certificate with a CA. The CA key has to live somewhere: Terraform state, or AWS Private CA (~$400/month, or ~$50/month short-lived mode) | The bundle makes the keys | The bundle makes the keys and registers the laptop's key with the hub | Nothing to issue; AWS IAM decides |
| Revoking | Upload a new revocation list to the endpoint | Decommission the bundle | Decommission the bundle; the hub drops the peer on its next sync | Remove the IAM permission |
| What the developer gets | Whole VPC, DNS works | Whole VPC, DNS works | Whole VPC, DNS works | One port at a time, no DNS, needs AWS credentials on the laptop |
| Moving parts | Endpoint, CA, revocation list, optional SAML | One small server per developer | Hub server, a sync job, address allocation between developers | An instance or ECS task to forward through |

Notes:

- **Client VPN** is the most "managed" choice, and it can log in with SAML instead of certificates, which would hand identity to the company's IdP rather than to Massdriver. It costs the most at every team size: its connection fee alone is more than a whole per-sandbox WireGuard server. Certificates also mean running a CA, which is more than this needs.
- **One WireGuard server per sandbox** is what the sketch builds. Each developer's server, keys and security group are their own, and decommissioning removes everything. It is cheap at small team sizes and has the fewest moving parts.
- **A shared hub** is cheaper past a handful of developers, but needs a second bundle (the hub, in the platform project) and a way for each sandbox to register its laptop key and get a free tunnel address. That could be a Parameter Store path the hub reads every minute. It is the natural next step if the per-sandbox cost becomes a problem.
- **SSM port forwarding** is free and needs no Massdriver resource at all, but it is not a VPN. Access is decided only by AWS IAM, so Massdriver ABAC never sees it, and developers need AWS credentials of their own.

## Where the keys are made

In the sandbox bundle, by OpenTofu (`OJFord/wireguard` for the key pairs, `random_bytes` for the preshared key). So:

- The laptop's private key is in the bundle's state and in the `tunnel` resource. The resource type marks it sensitive, so it is masked in the UI and API and only `resource:export` downloads it.
- The server's private key goes to Parameter Store as a SecureString. The server reads it at boot. It stays out of EC2 user data, which anyone who can describe instances can read.
- A redeploy keeps the keys. Rotating means replacing the key resources (`tofu apply -replace`), or decommissioning and deploying again.

The alternative is to make the laptop's key on the laptop, so no one else ever has it, and have the developer paste the public key into the form. That is safer, but the developer then builds `wg0.conf` themselves and the resource is less useful. Worth discussing.

## What the VPN reaches

The tunnel carries traffic for the whole VPC CIDR. Traffic leaves the server from its own private IP and security group. Two consequences:

- **The dev VPC is shared.** Every team's dev databases and caches are in it, including components tagged `data_classification=phi`. A developer on Patient Experience with a VPN is on the same network as Clinical's dev Charts database.
- **Security groups are the real gate.** The catalog's data bundles accept only their own client security group. So today a VPN user reaches nothing private until someone attaches a client group to the VPN server or allows the VPN's group. That is a good default, but it means "who may reach Charts" is decided in AWS, not in Massdriver.

ABAC decides who gets a `wg0.conf`. It does not decide what that file reaches.

## Access control (ABAC)

### What the current policies already do

From `examples/telehealth/bootstrap.tf`:

- Every team group has `resource:view` on everything (`conditions = "*"`). View shows the tunnel resource with keys masked. That is fine.
- Team groups get `resource:export`, deploy and the rest only in their own team's projects (`md-project`). `sandboxes` has `team = platform`, so today **only Platform Engineering can export a sandbox's tunnel**, which also means a developer may not be able to deploy into, or download from, their own sandbox. How sandbox-on-join grants the developer access to their own environment needs to be confirmed before anything else here.
- The `developer-vpn` bundle is granted only to the `sandboxes` project (`bundle_access`), so it can't be added beside prod.

### Strawman policy

The goal: a developer can export the tunnel in **their own** sandbox, and no one else's. Platform Engineering keeps access to all of them for support.

```hcl
# Per developer, created by sandbox-on-join with the sandbox.
resource "massdriver_group_policy" "sandbox_owner" {
  group_id   = <the developer's own group>
  effect     = "ALLOW"
  actions    = ["environment:deploy", "environment:decommission", "instance:configure",
                "instance:deploy", "instance:decommission", "resource:export"]
  conditions = jsonencode({
    "md-project"     = ["sandboxes"]
    "md-environment" = [<the sandbox's identifier>]
  })
}
```

Both keys are built-in and always resolve, so the policy can't widen. The cost is one group per developer, which the automation would have to make and delete.

A team-level version is simpler: every member of a team can export every sandbox of that team, using an environment attribute such as `sandbox_team`. Teammates could then download each other's keys. That may be acceptable for dev, or not.

### The silent-widening trap

Groups' policies add up (OR), and a condition key a resource can't resolve does not deny. It drops out, and the allow becomes organization-wide. For this feature that bites in two ways:

- A policy keyed on a custom attribute like `owner` or `sandbox_team` grants export on **every resource in the organization** that lacks the attribute, including prod databases' connection details.
- `team` is a project-level attribute, and the sandboxes project's `team` is `platform`. A policy like `{ "team": ["clinical"] }` would not match sandboxes at all, while a typo in the key would match everything.

Rule of thumb: every policy that grants `resource:export` includes `md-project`, which always resolves, alongside any custom attribute. Then test it: as a member of the group, try to export a prod resource and expect a refusal.

### Open questions

1. **Can a condition refer to the person asking?** Something like "environment attribute `owner` equals the caller's email" would remove the need for a group per developer. If ABAC can't do that, is one group per developer acceptable, or should the automation tag each sandbox and accept team-wide export?
2. **How does a developer get rights in their own sandbox today?** If sandbox-on-join grants nothing, the developer can't deploy the VPN or download `wg0.conf`, and only Platform Engineering can.
3. **Does a missing custom attribute really widen within a single policy that also has `md-project`?** If keys AND together and the missing one drops out, `md-project=sandboxes` still holds. If the whole policy is treated as unconditioned, it does not. This needs a test before any `owner`-style policy ships.
4. **Should anyone be able to download another developer's `wg0.conf`?** Platform Engineering has `*` everywhere, so it can. Is that wanted for support, or should even admins redeploy (new keys) instead of downloading?
5. **Is a shared dev VPC the right network for this?** A VPN into it reaches every team's dev data. The alternatives are a VPC per sandbox (more cost, more isolation) or per-team `allowed_ips` and security groups.
6. **Who decides which databases the VPN reaches?** Attaching a data bundle's client security group to the VPN server is an AWS change outside ABAC. Should the VPN bundle take client security groups as optional connections, so the decision is visible in Massdriver and logged as a deploy?
7. **Do keys belong in Massdriver state at all?** Making the laptop key on the laptop keeps it out of Massdriver, at the cost of a worse download experience.
