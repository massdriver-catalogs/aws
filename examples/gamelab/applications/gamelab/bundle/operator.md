---
templating: mustache
---
# Gamelab Server

{{#params.subdomain}}**Open Gamelab: https://{{params.subdomain}}.{{dependencies.cluster.zone.domain}}**{{/params.subdomain}}{{^params.subdomain}}**No address yet:** set **Subdomain** (e.g. `play`) and deploy.{{/params.subdomain}}

| | |
|---|---|
| Service | `{{params.md_metadata.name_prefix}}` on cluster `{{dependencies.cluster.name}}` ({{dependencies.cluster.region}}) |
| Image | `{{params.image_uri}}` |
| Size | {{params.size}} CPU/MB, {{params.desired_count}} task(s){{#params.spot}}, on Spot{{/params.spot}} |
| Acts in Massdriver as | the **Gamelab Server** service account (its token is the `MASSDRIVER_API_KEY` secret) |
| Makes labs from | `labs-template`, in the `labs` project |

## Nobody can sign in

- **"That's not the password."** The password is the `GAMELAB_PASSWORD` secret on this instance. Set a new one and deploy. From the example's folder, `./deploy.sh password` prints the one bootstrap made.
- **"Too many tries."** Wrong passwords lock sign-in for up to a minute. Wait, then try once.
- **Signed out right after signing in.** `SESSION_SECRET` changed, or two tasks have different ones. Deploy so every task reads the same secret.

## The labs page says "Couldn't reach Massdriver"

The message after the colon is Massdriver's answer.

- **`unauthorized` / HTTP 401:** the `MASSDRIVER_API_KEY` secret is wrong or the token was deleted. Rerun `./deploy.sh bootstrap` to remake the service account, then `./deploy.sh provision` to set the new token.
- **`forbidden` / not allowed:** the Gamelab Server service account lost its group or policies. Rerun `./deploy.sh bootstrap`.
- **A timeout:** the task can't reach the internet. Check the VPC's egress.

## A lab is stuck or says a deploy failed

Gamelab only starts deploys; Massdriver runs them. Open the lab's environment (`labs-<name>`) in Massdriver and read the failed deployment's logs. Then press **Try again** on the lab in Gamelab: it skips what's already done.

If Gamelab restarted while a lab was being built, the lab shows **Set up**. Press it to carry on.

## A lab is ready but the chat says the box isn't answering

The server reaches each box at its private name, on ports 4096 and 8080, from inside the VPC.

- **"isn't answering yet":** the box is starting or was replaced (Spot). Wait a minute.
- **"didn't accept its password":** `SESSION_SECRET` changed since the lab was made. Press **Try again** on the lab, or deploy its box: Gamelab sets the password again.
- Otherwise see the lab box's own guide on its instance in Massdriver.

## A lab says "Waking up your lab…" for more than a few minutes

The server set the box's service back to one task, and the task isn't answering. Read the box's events, then see the lab box's own guide on its instance in Massdriver:

```bash
aws ecs describe-services --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --services $(aws ecs list-services --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --query 'serviceArns[?contains(@, `/labs-<name>-box`)]' --output text | sed 's|.*/||') \
  --query 'services[0].[desiredCount,runningCount,events[:5]]'
```

- **`AccessDeniedException` on `UpdateService`** in this server's log: the **Lab Power** policy isn't on the task role. Deploy Lab Power, then this server.
- **desiredCount 1, runningCount 0** for minutes: the box can't start; the cause is in its events.

## Labs never go to sleep

The log line `labs sleep when unused` at start says the idle time. Without it, the task has no AWS configuration. With it but no `lab asleep` lines, look for `putting lab to sleep` errors: the **Lab Power** policy is missing or doesn't cover the box's service. A lab whose box was deployed before sleep existed needs one more deploy to say which service it is.

## Read the logs

```bash
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 30m --follow
```

Every lab setup step logs a line with `"lab":"labs-<name>"`; failures say which step.

## Ship a new version

```bash
cd examples/gamelab && ./deploy.sh ship
```
