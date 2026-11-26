# Tendwell Supply: a PHP fleet mid-upgrade

Tendwell Supply is the home-health supply shop that Tendwell Health runs beside its telehealth apps. It is seven small PHP services, each its own application bundle on the `ecs-service` runtime. The platform team has shipped several runtime versions, and the shop's teams have moved to them at different speeds. Some apps are built on the newest runtime, some are still on old ones, and some instances run an older app version than their app's newest.

Open **Runtimes → ecs-service** in Massdriver to see the rollout.

## The fleet

| App | Versions published (runtime) | Instance runs |
|---|---|---|
| storefront | 1.3.0 (dev1), 1.4.0 (latest) | 1.4.0, on the latest runtime |
| checkout | 2.0.0 (dev3), 2.1.0 (latest) | 2.0.0, one version behind its app |
| inventory | 0.9.0 (latest) | 0.9.0, on the latest runtime |
| accounts | 1.2.0 (dev3) | 1.2.0 |
| search | 0.5.0 (dev1), 0.6.0 (dev2) | 0.5.0, one version behind its app |
| reviews | 0.3.0 (dev2) | 0.3.0 |
| admin | 3.0.0 (dev1) | 3.0.0, on the oldest runtime |

`latest` is the newest stable `ecs-service`. `dev1` to `dev3` are the runtime's first three development releases, oldest first. [versions.txt](versions.txt) holds this table; change it to tell a different story.

Every service is a PHP 8.3 Apache page at `https://<app>.<dev zone>`, on the platform's dev cluster, with the smallest Fargate task on Spot. About $20 a month for all seven.

## Stand it up

Needs the [telehealth example](../telehealth)'s platform deployed to dev in the same organization, and AWS CLI credentials for its account.

```bash
cd examples/php-fleet
./deploy.sh all
```

That publishes the runtime's development releases if there aren't three yet, creates the `phpfleet` project with its dev environment, publishes every app version, builds the PHP image and deploys each instance on its version.

## Reset it

After someone upgrades an instance, or to try a new `versions.txt`:

```bash
./deploy.sh publish   # versions not published yet
./deploy.sh deploy    # every instance back on its version
```

## Tear it down

```bash
./deploy.sh teardown
```

This decommissions the instances and destroys the project and the app bundles. The runtime's development releases stay. Tear this down before the telehealth example's platform; the services hold rules on its load balancer and records in its zone.
