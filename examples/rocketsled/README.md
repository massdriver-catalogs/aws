# Rocketsled

<img src="logo.png" alt="Rocketsled" width="96">

Rocketsled builds a PaaS out of Massdriver bundles. This example builds two knock-offs on this catalog and runs them side by side in one Massdriver organization:

- **Fauxroku**, a Heroku. Pick Node.js, Ruby or Python, name an environment `staging`, and get web dynos at `https://ruby-staging.apps.example.com`. Add a worker, Postgres or a Key-Value Store and `DATABASE_URL` and `REDIS_URL` are set. Push a buildpack-built image and it runs.
- **Fauxcel**, a Vercel. Pick Functions or Static, and get an HTTPS endpoint with a function or a static site behind it, plus KV and Blob storage if you want them. It costs nothing until someone calls it.

Customers never see Massdriver and never bring an AWS account: the PaaSes run on the operator's, like the real ones. Each customer environment is a Massdriver environment forked by that PaaS's Rocketsled server from a runtime's template, the way the Gamelab server forks labs. [TOPOLOGY.md](TOPOLOGY.md) explains the model: a platform deployed once, a template per runtime, environments as forks, add-ons deployed or not, promotion by copy.

## How it fits together

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture.dark.svg">
  <img src="diagrams/architecture.svg" alt="A developer signs in to the Rocketsled servers, one for fauxroku.yaml and one for fauxcel.yaml, and makes environments; each server forks and deploys through the Massdriver API as its own service account. In the operator's AWS account, the developer reaches web dynos on Fargate Spot over HTTPS through the load balancer at *.apps.example.com, and functions or the static file server on Lambda through the HTTP API's execute-api URL. Web and worker dynos use Postgres and the Valkey key-value store in the platform VPC; functions use DynamoDB KV and S3 blob or files. One image repository per runtime holds the images for the dynos and functions.">
</picture>

Dashed lines are add-ons: there only where the customer picked them.

## Fauxroku

Three runtimes, `node`, `ruby` and `python`, each a project with a template. Every Fauxroku environment runs on the shared platform (`vpc` with a NAT instance, `dns-zone`, `ecs-cluster`), so it costs only its own dynos and add-ons.

| Component | Bundle | Add-on | What the developer gets |
|---|---|---|---|
| Web Dynos | `fauxroku-node`, `fauxroku-ruby` or `fauxroku-python`, on `ecs-service` | no | Their image at `<runtime>-<environment>.<DOMAIN>`, with `PORT` and the language's production defaults |
| Worker Dynos | `fauxroku-worker` on `ecs-service` | yes | The same image with no address and `PROCESS_TYPE=worker` |
| Postgres | `postgres` | yes | RDS PostgreSQL; `DATABASE_URL` and `PGPASSWORD` |
| Key-Value Store | `valkey` | yes | ElastiCache Serverless Valkey; `REDIS_URL` (TLS) |
| Image Repository, Codebase | `ecr-repository`, `codebase` | deployed in the template | Where `pack build --publish` sends the image |

| Plan | What you get | About |
|---|---|---|
| Web or worker, Development | 1 dyno, 0.25 vCPU, 0.5 GB | $7/month, $2 on Spot |
| Web or worker, Production | 2 dynos, 1 vCPU, 2 GB, up to 6 when busy | $58/month |
| Postgres, Development | db.t4g.micro, 20 GB, 1 day of backups | $15/month |
| Postgres, Production | db.m7g.large with a standby, 100 GB, 14 days of backups | $285/month |
| Key-Value Store, Development | up to 1 GB | $6/month |
| Key-Value Store, Production | up to 10 GB, snapshots | $65/month |
| Shared platform | VPC with a NAT instance, DNS zone, load balancer | $25/month in all |

`./bootstrap.sh fork ruby staging` makes the cheapest environment: one web dyno on Spot, about $2 a month on top of the platform. `./bootstrap.sh fork ruby staging db cache` adds Postgres and a Key-Value Store.

## Fauxcel

Two runtimes, `functions` and `static`. Nothing is shared and nothing runs while idle.

| Component | Bundle | Add-on | What the developer gets |
|---|---|---|---|
| Endpoint | `http-api` | no | An HTTPS URL on execute-api |
| Functions | `fauxcel-functions` on `lambda-function` | no (functions) | Their arm64 image answering every route, with `KV_TABLE` and `BLOB_BUCKET` |
| KV | `dynamodb-table` | yes (functions) | An on-demand table the function can read and write |
| Blob | `s3-bucket` | yes (functions) | A private bucket the function can read and write |
| Site | `fauxcel-static` on `lambda-function` | no (static) | A small file server that serves the Files bucket, with single-page-app fallback |
| Files | `s3-bucket` | no (static) | Where `aws s3 sync dist/` deploys to |
| Image Repository, Codebase | `ecr-repository`, `codebase` | deployed in the template | The function's image; for static, the file server built once |

Every Development preset fits in AWS's free tier or bills per request. What Vercel has and this catalog doesn't: an edge cache in front (there's no CloudFront bundle yet, so the static site is served by a function rather than from the edge) and public Blob URLs (`s3-bucket` is private by design).

## The Rocketsled side

[`fauxroku.yaml`](fauxroku.yaml) and [`fauxcel.yaml`](fauxcel.yaml) each run one Rocketsled server for one PaaS, wearing its skin from [`skins/`](skins/): Fauxroku's purple gradients and beveled buttons, Fauxcel's black, white and monospace. Anyone with the site's password signs in under a name, picks a runtime, a plan and add-ons, and watches their app deploy; each name sees only its own apps. `paas.limits` keeps that cheap: two apps a person, the Development plans only, and every app removed 24 hours after it was made.

| Key | What it does | Issue |
|---|---|---|
| `massdriver.account_mode: tenant`, `paas` | Serve forks of existing templates; no install, no customer credential | [#10](https://github.com/massdriver-cloud/rocketsled/issues/10) |
| `skin` | Name, logo, design tokens, layout, copy and CSS, loaded at runtime | [#14](https://github.com/massdriver-cloud/rocketsled/issues/14) |
| `paas.runtimes` | Several templates per PaaS; the customer picks one | [#16](https://github.com/massdriver-cloud/rocketsled/issues/16) |
| `paas.pinned` | Params every environment gets whatever the plan, like its own subdomain | [#11](https://github.com/massdriver-cloud/rocketsled/issues/11) |
| `paas.addons` | Deploy an add-on or don't | [#3](https://github.com/massdriver-cloud/rocketsled/issues/3) |
| `paas.plans` | Prices on plan cards | [#8](https://github.com/massdriver-cloud/rocketsled/issues/8) |
| `paas.highlights` | What the app page shows from each resource | [#9](https://github.com/massdriver-cloud/rocketsled/issues/9) |
| `paas.limits` | Apps per person and in all, allowed plans and add-ons, time to live | |
| `app_component`, `image_param` | Where a release lands: a build sends an image with a deploy token, and an older image can be rolled back to | [#5](https://github.com/massdriver-cloud/rocketsled/issues/5) |
| `paas.pipeline` | Stages, and promoting one stage's build to the next by copy | [#4](https://github.com/massdriver-cloud/rocketsled/issues/4) |
| `paas.previews` | A preview app per branch or pull request, removed after 6 quiet hours | [#6](https://github.com/massdriver-cloud/rocketsled/issues/6) |

Two keys are left out on purpose:

- `paas.platform` would have the Fauxroku server check the platform layer and share it with every runtime. `./bootstrap.sh provision` already shares it and pins it on every template, so forks get it without the server ([#15](https://github.com/massdriver-cloud/rocketsled/issues/15)).
- `paas.domains` puts a customer's own hostname on the web dynos' `subdomain` param, and `ecs-service` takes one label there, not a hostname. Custom domains need an `ecs-service` param for extra hostnames and their certificate first ([#7](https://github.com/massdriver-cloud/rocketsled/issues/7)).

### What a customer can do

| | Fauxroku | Fauxcel |
|---|---|---|
| Make an app | Pick Node.js, Ruby or Python, and a stage | Pick Functions or Static, and a stage |
| Add-ons | Add or remove a worker, Postgres or Key-Value Store after the app is made; the dynos redeploy with `DATABASE_URL` or `REDIS_URL` set or cleared | Add or remove KV or Blob; the function redeploys with `KV_TABLE` or `BLOB_BUCKET` |
| Release | Make a deploy token, then push an image from CI | The same, for a Functions app |
| Roll back | Pick an older release on the app page | The same |
| Promote | Development to Staging to Production: the image and config move, and each stage keeps its own plan and add-ons | Preview to Production |
| Preview | One app per pull request, made by the first push and removed when the pull request closes | The same, for a Functions app |

```bash
# release to the app named staging
curl -X POST "https://fauxroku.<DOMAIN>/api/v1/environments/staging/releases" \
  -H "Authorization: Bearer $FAUXROKU_DEPLOY_TOKEN" -H 'content-type: application/json' \
  -d '{"image": "<registry>:abc123", "description": "abc123"}'

# make or update the preview for pull request 42, and remove it when the pull request closes
curl -X PUT "https://fauxroku.<DOMAIN>/api/v1/previews/pr42" \
  -H "Authorization: Bearer $FAUXROKU_DEPLOY_TOKEN" -H 'content-type: application/json' \
  -d '{"image": "<registry>:abc123", "runtime": "ruby"}'
curl -X DELETE "https://fauxroku.<DOMAIN>/api/v1/previews/pr42" -H "Authorization: Bearer $FAUXROKU_DEPLOY_TOKEN"
```

Deploy tokens and release history live in the server's database on the task's disk, so a new task starts without them; apps, their stages and add-ons come back from Massdriver.

## Stand it up

In Massdriver, give the organization `logo.png` as its icon (**Settings → General**). Then:

```bash
export MASSDRIVER_PROFILE=rocketsled
DOMAIN=apps.example.com PARENT_ZONE_ID=Z0123456789 ./bootstrap.sh all
./bootstrap.sh fork static demo      # free while idle
./bootstrap.sh fork ruby staging     # about $2/month on top of the platform
```

`all` publishes every bundle as a development release, applies [`bootstrap.tf`](bootstrap.tf) (the platform project, a project and template per runtime, a service account per PaaS, the AWS credential), deploys the platform and each template's image repository and codebase (about $25 a month in all), builds the static file server, and writes `.env` with both servers' Massdriver keys. Every step asks before it touches AWS.

Then run both websites on the platform's cluster, from a Rocketsled checkout next to this repository (about $4 a month on Spot):

```bash
./bootstrap.sh servers     # https://fauxroku.<DOMAIN> and https://fauxcel.<DOMAIN>
```

Or run one on your machine:

```bash
FAUXROKU_BASE_URL=http://localhost:8081 bin/rocketsled serve -config ../aws/examples/rocketsled/fauxroku.yaml -env-file ../aws/examples/rocketsled/.env
```

`./bootstrap.sh teardown` removes every customer environment, the templates' repositories, the platform and everything `bootstrap.tf` made.

## Files

```
TOPOLOGY.md                  platform, runtimes, environments, add-ons, promotion
bootstrap.tf                 the projects, templates, links, credential and server accounts
bootstrap.sh                 role, publish, projects, provision, fork, env, teardown
blueprint.draft.yaml         the six canvases as files
fauxroku.yaml, fauxcel.yaml  the Rocketsled servers
server/                      their image: Rocketsled with these configs and skins
skins/                       each PaaS's look: skin.json, logo.svg, skin.css
applications/fauxroku-*      web dynos per language, and the worker, on ecs-service
applications/fauxcel-*       functions, and the static file server, on lambda-function
applications/rocketsled-server  the websites themselves, on ecs-service
```
