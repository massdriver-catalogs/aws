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

Automations come from [massdriver-automations](https://github.com/massdriver-cloud/massdriver-automations). Tendwell runs them in the `automations` project, one instance each (`automations-main-<name without dashes>`, such as `automations-main-rollbackonfailure`), configured in `examples/telehealth/automations.yaml`. A key there turns an automation on, and its `config` is that automation's config file. `bootstrap.sh provision dev` deploys them and creates their event destinations.

Secrets an automation needs (a run token, a GitHub token) are set on its instance with the `setInstanceSecret` GraphQL mutation, never in `automations.yaml`. A secret reaches the running task only on the instance's next deploy: until then a run endpoint answers 404.

### Change one

The images are tagged `latest`, and a deploy restarts the task on whatever `latest` is then. So after a change merges to massdriver-automations main, wait for its **Publish** workflow (`gh run list --workflow publish.yml -R massdriver-cloud/massdriver-automations`, about 11 minutes), then redeploy:

```bash
mass instance deploy automations-main-drift -m "Pick up the new image"         # same params
mass instance deploy automations-main-freezeguard -m "..." \
  --patch '.config.windows += [{"name": "test", "match": {"md-environment": "prod"}, "from": "2026-11-27 15:00", "to": "2026-11-27 16:50"}]'
```

The running version is in every log line: `"version":"<commit>"`. Logs are in CloudWatch, one group per automation:

```bash
aws logs filter-log-events --log-group-name /ecs/tendwell-health-automations-main-drift-drift \
  --start-time $(( ($(date +%s) - 600) * 1000 )) --query 'events[].message' --output text | tr '\t' '\n' | grep -v healthz
aws logs describe-log-groups --log-group-name-prefix /ecs/tendwell-health-automations-main- --query 'logGroups[].logGroupName'
```

Things that bite:

- **Never deploy an automation with `--params`.** `mass instance deploy --params` expands `$name` in every value, so jq variables such as log-results' `$action` become empty and the config fails to load. Use `--patch` with the change, or with the whole params as a JSON literal; `bootstrap.sh` does the latter.
- **Keep configs ASCII.** A deploy fails right after Checkov when Checkov prints a resource holding a character outside ASCII. Write `\x{2502}` in a regular expression and `\u2713` in Python, never the character.
- **A refused deploy still saves its params.** When `mass instance deploy` fails schema validation, the instance keeps the invalid params, and the next `--patch` starts from them. Patch the bad field back.
- **A dev release sorts before its release.** `0.0.0-dev.<time>` is older than `0.0.0`, so an instance on `0.0.0` never picks it up. Bump `version` in the bundle's `massdriver.yaml` before `mass bundle publish -d`.
- **A release channel upgrades by itself.** An instance whose version is a channel such as `~0+dev` is redeployed by Massdriver the moment a matching release is published ("Release channel ~0 upgrading to ..."), before any upgrade-train stage. Tendwell's instances are pinned to exact versions; a pin like that is only for a test, and goes back after.
- **Three deployments at a time, org-wide.** Drift and chaos-monkey plans count. Check before starting more: the `deployments(filter: {status: {in: [PENDING, APPROVED, RUNNING]}})` query.

### Exercise each one

| Automation | Do this | See this |
|---|---|---|
| rollback-on-failure | `mass instance deploy visits-dev-app --patch '.image_uri \|= sub(":[^:]+$"; ":missing")' -m "Rollback test"`. The four apps have `autorollback=true`; the API and data stores don't. | The deploy fails, then `Rollback to deployment <id>` runs and completes within a minute, with `md/v1/step/rollback` on it. The app's saved params are the good ones again. Its completion also cascades: care-dev-app, then billing-dev-app redeploy. |
| drift | Change a tag on a dev resource: `aws dynamodb tag-resource --resource-arn <slots table arn> --tags Key=team,Value=drift-test`. Then `curl -X POST -H "Authorization: Bearer $DRIFT_TOKEN" "https://drift.dev.$DOMAIN/drift/run?check=drift-daily"`. Put the tag back after. | `drift-daily` plans every dev app-project instance, three at a time (about 15 minutes for twelve). `md/v1/drift` = `detected` on visits-dev-slots and `md/v1/changes/drift` on each plan. Expect more: Massdriver rewrites an alarm's name and statistic when the alarm changes state, so most instances with alarms plan a `massdriver_instance_alarm` update and read as drifted. Prod isn't planned while it isn't provisioned. |
| autodeploy-downstream | `mass instance deploy visits-dev-slots -m "..."`. | visits-dev-app and visits-dev-notifier deploy with the message `Auto-deploy (rule dev-upstream-changes) ...` and `md/v1/step/autodeploy`; their completion carries on to care-dev-app and billing-dev-app. |
| upgrade-train | Massdriver doesn't send `repo.published` yet, so start a run by hand: `curl -X POST -H "Authorization: Bearer $TRAIN_TOKEN" "https://upgrade-train.dev.$DOMAIN/upgrade-train/run?train=tendwell-apps&bundle=tendwell-visits&version=<version>"` (the token is the instance's `UPGRADE_TRAIN_TOKEN` secret). During the 15-minute soak, `aws cloudwatch set-alarm-state --alarm-name tendwell-health-visits-dev-app-errors --state-value ALARM --state-reason test`; set it back to `OK` after. | The dev stage deploys, or counts as done an instance already on the version, and lists the instances left out because their constraint doesn't resolve to it. The alarm stops the run within a minute: `train halted`. The same `run` call resumes it. |
| freeze-guard | Patch a window that covers now into its config (above) and redeploy it. | A `DENY` policy on `instance:deploy`, `instance:decommission`, `environment:deploy` and `environment:decommission` with `md-environment: prod` on every custom group except Platform Engineering. Organization Admin is never frozen, so to see a denied deploy, sign in as someone only in a team group. Redeploy without the window and the policies go. |
| statuspage | `mass alpha stash set visits-dev-app.md/v1/health down` | The component goes to an outage on `https://statuspage.dev.$DOMAIN/dev/` (JSON at `https://statuspage.dev.$DOMAIN/api/status.json`). `healthy` brings it back. A `warning` or `error` banner on a dev environment shows as a notice. |
| sandbox-on-join | Add a person in `sandbox_owners` (`terraform.tfvars.json`) to a team group. | An environment `sandboxes-<email local part>` forked from the template, with `owner` and `sandbox=true`. It isn't deployed (`deploy: false`). Remove them and it's deleted. Service accounts are ignored. |
| chaos-monkey | `curl -X POST -H "Authorization: Bearer $CHAOS_TOKEN" "https://chaos-monkey.dev.$DOMAIN/chaos-monkey/run?strategy=preset"` (also `merge`, `mutate`, `gibberish`) | One PLAN on a random visits, care or billing dev instance with made-up params, and `md/v1/step/chaos-monkey` on it. Gibberish is usually refused by the bundle's schema, and the log says so. |
| stash-sync | `demo/sim.sh traffic 5` | `md/v1/health`, `md/v1/usage` and `md/v1/traffic` on the dev instances, rewritten every two minutes. |
| log-results | Deploy, plan or break any instance. | `md/v1/step/src`, `md/v1/changes/src` and `md/v1/compliance/src` on the deployment. A failed step's message is the OpenTofu error. |
| leaderboard | Nothing to do: it writes a fixed list every 15 minutes. Check with `mass alpha stash get visits-dev.md/v1/leaderboard`. | The leaderboard card on visits-dev, "Most deploys this week", with five people and their avatars. Each write lasts three intervals, so the card empties about 45 minutes after the automation stops. A route with `pull_requests` instead of `static` scores real pull requests once the instance has a `GITHUB_TOKEN` secret. |
| oncall | Nothing to do: it writes a fixed list every two minutes. Check with `mass alpha stash get visits-dev.md/v1/oncall`. | The on-call card on visits-dev, "Visits on call", with Dana Smith (primary) and Lee Park (secondary). Each write lasts three intervals, so the card empties about six minutes after the automation stops. A `pagerduty` or `incident_io` route reads a real schedule once the instance has `PAGERDUTY_TOKEN` or `INCIDENT_IO_API_KEY`. |
| router | Deploy anything. | `✓ visits-dev-app provisioned by ...` or `✗ ... failed` lines in its log. |
| stale-proposals | Propose a deploy and leave it. | The digest in its logs on the next weekday run, 8:37 Pacific. |
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

- **A deployment stays RUNNING or PENDING for a long time.** With more than three in flight, a plan can sit in "Refreshing state" for ten minutes; that is slow, not stuck. Past fifteen minutes, `mass deployment abort <id> --force`.
- **"Plugin did not respond" or "timeout while waiting for plugin to start".** The runners are overloaded. Wait until fewer deployments are in flight and deploy again.
- **A deploy fails right after "Evaluating Checkov policies..." with only "Error: exit status 1".** A param holds a character outside ASCII. Find it with `mass instance get <instance> -o json | jq .params` and escape it.
- **"state is already locked".** Check that nothing of the instance is running, then call the `forceUnlockInstanceState(organizationId, id, step: "src")` mutation.
- **An instance won't decommission because it's "in use".** It's an environment default somewhere. Remove the default first.
- **An S3 bucket won't decommission.** Empty it first.
- **A widget doesn't show.** `mass alpha stash list <scope>` and check the key, the format (`--format json`) and that the entry hasn't expired.
