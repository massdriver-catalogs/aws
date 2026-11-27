---
name: tendwell
description: Stand up Tendwell Health, the AWS catalog's telehealth example, in a Massdriver organization, run its automations for real, and make its canvases look busy for a demo with traffic, banners, widgets, notes, alarms and deployment results. Use when someone wants to set up Tendwell, exercise or debug its automations, show off annotations and the stash, or run a quick demo simulation.
---

# Tendwell

Tendwell Health is a telehealth company made of three apps on AWS: **visits** (booking, reminders), **care** (sessions, charts, documents) and **billing** (claims, ledger). It lives in `examples/telehealth/` of the AWS catalog. Everything here runs from that directory.

## What you need

- `mass`, signed in to the organization, with the `alpha stash` commands. Check with `mass alpha stash --help`.
- `tofu`, `jq`, `python3` with PyYAML, `docker`, and AWS CLI credentials for the account the apps deploy into.
- A domain you control in Route 53 (`DOMAIN`). Each stage answers at `<app>.<stage>.<DOMAIN>`.
- The organization's service account in the **Organization Admin** group. A new organization puts it in no group, and publishing fails until it joins.

Never print a secret. Keys and tokens go into instance secrets, never into files, logs or chat.

## Stand it up

```bash
cd examples/telehealth
export DOMAIN=example.com PARENT_ZONE_ID=Z123...   # PARENT_ZONE_ID delegates each stage's zone for you
./bootstrap.sh all dev                             # role, costs, setup, publish, projects, provision, ship
```

Or one step at a time: `role`, `costs`, `setup`, `publish`, `projects`, `provision dev`, `ship <app> dev`. `./bootstrap.sh` with no arguments lists them. `teardown` removes everything.

Deploy at most three instances at a time. More than that overloads the runners, and deployments fail with "timeout while waiting for plugin to start".

## Automations

Automations come from [massdriver-automations](https://github.com/massdriver-cloud/massdriver-automations). Tendwell runs them in the `automations` project, one instance each, configured in `examples/telehealth/automations.yaml`. A key there turns an automation on, and its `config` is that automation's config file. `bootstrap.sh provision dev` deploys them and creates their event destinations.

Secrets an automation needs (a run token, a GitHub token) are set on its instance with the `setInstanceSecret` GraphQL mutation, never in `automations.yaml`.

### Exercise each one

| Automation | Do this | See this |
|---|---|---|
| rollback-on-failure | Deploy `visits-dev-api` with a param that fails the apply. Its instance has `autorollback=true`. | The failed deployment, then the last good one runs again. |
| drift | Change a tag or security group on a Tendwell resource in the AWS console, then start a check: `curl -X POST -H "Authorization: Bearer $TOKEN" "https://drift.dev.$DOMAIN/drift/run?check=<name>"` | A plan deployment, `md/v1/drift` = detected on the instance, `md/v1/changes/drift` on the plan. |
| autodeploy-downstream | Deploy `visits-dev-slots`. | The app and API that depend on it deploy next, each with a step result naming the upstream. |
| upgrade-train | Publish a development release of a Tendwell bundle. | Each stage deploys it, `md/v1/release` on the instances. Fire an alarm and the train stops. |
| freeze-guard | Add a window that covers now to its config and redeploy it. | A prod deploy is denied in the UI. Remove the window and it works. |
| statuspage | `mass alpha stash set visits-dev-app.md/v1/health down` | The component goes to an outage on `https://statuspage.dev.$DOMAIN/dev/`. `healthy` brings it back. |
| sandbox-on-join | Add a person to the configured group. | A forked environment named after them appears and deploys. Remove them and it is decommissioned. |
| chaos-monkey | `curl -X POST -H "Authorization: Bearer $TOKEN" "https://chaos-monkey.dev.$DOMAIN/chaos-monkey/run?strategy=preset"` | Plan deployments with made-up params, each with a step result. |
| stash-sync | Send traffic: `demo/sim.sh traffic 5` | Status dots, usage bars and traffic on the canvas lines, from CloudWatch, within two minutes. |
| log-results | Deploy any instance. | `md/v1/step/src`, `changes/src` and `compliance/src` in the deployment's details. |
| params-to-git | Deploy any instance with `strategy: stdout`. | The rendered `params.json` in the automation's logs, secrets masked. |
| stale-proposals | Propose a deploy and leave it. | The digest in its logs on the next weekday run. |
| cost-explorer | Open `https://cost-explorer.dev.$DOMAIN/`. | Costs grouped by any attribute. |

## Simulate for a demo

`demo/sim.sh` makes a stage look busy without changing infrastructure. It needs `DOMAIN` and, for alarms, AWS credentials.

```bash
cd examples/telehealth/demo
export DOMAIN=example.com
./sim.sh all 20          # 20 minutes of traffic, banners, a merge queue and alarms outside visits
./sim.sh flap 5          # a banner that changes color every 30 seconds
./sim.sh results         # step, changes and compliance on visits-dev-app's latest deployment
./sim.sh metadata        # release, on call and feature flags on the visits instances
./sim.sh deploys 6       # deploys that change nothing across care and billing
./sim.sh clear           # remove the banners, links, pull requests and metadata
```

Traffic is real: requests hit the Visits, Care and Billing APIs, so stash-sync draws real numbers from CloudWatch. Everything else is stash entries, which expire on their own or go with `clear`.

## Widgets and notes

Widgets read well-known stash keys. `md/` is reserved: the server rejects an `md/` key that isn't in its catalog, is on the wrong scope, or doesn't match the schema.

| Key | Scope | Widget |
|---|---|---|
| `md/v1/health` | instance | status dot: `healthy`, `degraded`, `down` |
| `md/v1/usage` | instance | usage bar: `{"value": 37, "max": 100, "label": "connections"}` |
| `md/v1/traffic` | instance | traffic on the lines that leave it: `{"rps": 240, "errors_5m": 2, "p95_ms": 180}` |
| `md/v1/banner` | environment | banner: `{"message": "...", "level": "info"}` (`warning`, `error`) |
| `md/v1/links` | environment | header buttons: `{"links": [{"label": "Runbook", "url": "https://..."}]}` |
| `md/v1/step/{step}`, `md/v1/changes/{step}`, `md/v1/compliance/{step}`, `md/v1/tests`, `md/v1/source`, ... | deployment | deployment results |
| `md/v1/drift`, `md/v1/release` | instance | drift and the running release |

Any entry with `--label` shows as a metadata row on its instance, deployment or project.

Notes are Liquid, pinned by right-clicking an instance, a line, or empty canvas, or with **+** next to the project name. Only the person who pins a note sees it. A project note that shows the merge queue from `sim.sh prs`:

```liquid
### Pull requests
{% for pr in project.stash["github/prs"].prs %}
- {% case pr.state %}{% when "merged" %}✅{% when "merging" %}🔄{% when "checks" %}🧪{% when "failed" %}❌{% else %}⏳{% endcase %} [{{ pr.repo }}#{{ pr.number }}]({{ pr.url }}) {{ pr.title }} · **{{ pr.state }}**
{% endfor %}
```

An instance note that turns red with health:

```liquid
{% assign h = instance.stash["md/v1/health"] | default: "unknown" %}
{% case h %}{% when "healthy" %}🟢{% when "degraded" %}🟡{% when "down" %}🔴{% else %}⚪{% endcase %} **{{ h | upcase }}**
{% assign t = instance.stash["md/v1/traffic"] %}{% if t %} · {{ t.rps }} req/s{% endif %}
```

## When something is stuck

- **A deployment stays RUNNING or PENDING for a long time.** `mass deployment abort <id> --force`.
- **"state is already locked".** Check that nothing of the instance is running, then call the `forceUnlockInstanceState(organizationId, id, step: "src")` mutation.
- **An instance won't decommission because it's "in use".** It's an environment default somewhere. Remove the default first.
- **An S3 bucket won't decommission.** Empty it first.
- **A widget doesn't show.** `mass alpha stash list <scope>` and check the key, the format (`--format json`) and that the entry hasn't expired.
