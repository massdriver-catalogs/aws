# DNS Zone

The domain for one environment, such as dev.example.com. Deploy one in each environment and set it as the environment default. APIs and services there then put their own names under it, like api.dev.example.com, and serve HTTPS with its certificate.

## What it needs

- An AWS IAM role that Massdriver can assume in the target account.
- A domain you control. Either this bundle makes a new Route 53 hosted zone for it, or you give it the ID of a public hosted zone that already exists in the account.

## What it makes

- The hosted zone, when you choose a new one. Its name servers are part of the output.
- An ACM certificate for the domain and for `*.domain`, in the region you pick. It covers names one level under the domain, such as api.dev.example.com, but not a.b.dev.example.com.
- The DNS records that prove to ACM that you own the domain. ACM uses them again to renew the certificate every year, so leave them in place.
- An alarm when the certificate is less than 30 days from expiry, which means renewal is failing.
- With **Sign the zone (DNSSEC)** on, a KMS signing key in us-east-1 and a key-signing key for the new zone. The parent zone or registrar needs the zone's `DS` record before resolvers check the signatures.

## A new zone needs delegation

A new hosted zone is not reachable until the parent domain points to it. For dev.example.com, add an `NS` record for `dev` in the example.com zone, with this zone's four name servers. If the domain is the top of what you own, such as example.com, set the name servers at your registrar.

The certificate can only be issued after that. The first deploy waits for it, up to **Certificate validation timeout**. Add the delegation while the deploy waits. If it times out, add the delegation and deploy again.

## Region

Certificates in ACM belong to one region. Load balancers and API Gateway can only use a certificate in their own region, so pick the region your environment runs in. CloudFront always needs a certificate in us-east-1.

## Decommissioning

Decommission the bundles that made records in the zone first. A zone this bundle made is only deleted when it is empty. A zone you brought is never deleted; only the certificate and its validation records are removed.
