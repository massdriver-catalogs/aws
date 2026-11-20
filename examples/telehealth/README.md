# Tendwell Health

A telehealth company built on this catalog. Patients book video visits, clinicians chart them, and a billing team files the insurance claims.

| Project | Team | What runs there |
|---|---|---|
| `platform` | Platform Engineering | `vpc`, `dns-zone`, `ecs-cluster`, `github-actions-oidc` |
| `apps` | Platform Engineering | App onboarding: `ecr-repository`, `massdriver-project`, `github-repo`, `codebase` |
| `visits` | Patient Experience | The booking API on Lambda: `http-api`, `dynamodb-table`, `sqs-queue`, `tendwell-visits` twice (the API, and the reminder sender) |
| `care` | Clinical | The clinician portal on ECS: `postgres`, `valkey`, `s3-bucket`, `tendwell-care` |
| `billing` | Revenue | Claims on ECS: `mariadb`, `s3-bucket`, `tendwell-billing` |

`platform`, `visits`, `care` and `billing` each have `dev`, `staging` and `prod`. Prod deploys need a second person's approval.

```mermaid
flowchart LR
  subgraph platform
    network[vpc] --> cluster[ecs-cluster]
    dns[dns-zone] --> cluster
  end
  subgraph visits
    api[http-api] --> vapp[tendwell-visits]
    slots[(dynamodb-table)] --> vapp
    q[sqs-queue] --> vapp
  end
  subgraph care
    pg[(postgres)] --> capp[tendwell-care]
    vk[(valkey)] --> capp
  end
  subgraph billing
    db[(mariadb)] --> bapp[tendwell-billing]
  end
  vapp -- tendwell-visits-api --> capp
  capp -- tendwell-care-api --> bapp
  platform -. environment defaults .-> care
  platform -. environment defaults .-> billing
```

## The apps

Each app in [applications/](applications/) has:

- `src/`: the app and its Dockerfile.
- `bundle/`: the app's bundle. It has no infrastructure code of its own: it runs on the catalog's `lambda-function` or `ecs-service` runtime, and adds the app's connections and the resource it publishes.
- `resource-type/`: that resource, so other apps connect to it by contract. Care reads the Visits API's URL; Billing reads Care's.
- `blueprint.draft.yaml`: the project's design as a file, in the draft blueprint format.

## Stand it up

You need an organization with a service account in the Organization Admin group, an AWS role made from the AWS IAM Role credential's instructions, and a domain whose Route 53 zone is in the nonprod account.

```bash
export MASSDRIVER_API_KEY=... MASSDRIVER_ORG_ID=...
export DOMAIN=tendwell.example PARENT_ZONE_ID=Z0123456789ABCDEFGHIJ
cp terraform.tfvars.example terraform.tfvars   # your role ARNs

./deploy.sh all dev
```

That publishes the catalog and the apps, applies [bootstrap.tf](bootstrap.tf) (projects, environments, components, links, groups, policies and the AWS credentials), deploys dev, and builds and ships each app. The apps then answer at `visits.dev.<domain>`, `care.dev.<domain>` and `billing.dev.<domain>`.

Run `./deploy.sh` alone to see the individual steps.
