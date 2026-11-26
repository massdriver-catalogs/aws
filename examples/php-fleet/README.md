# Tendwell Supply: a PHP fleet mid-upgrade

Tendwell Supply is the home-health supply shop that Tendwell Health runs beside its telehealth apps. It is seven small PHP services, each its own application bundle on the `ecs-service-php7` runtime. Each runtime version is a PHP release, so the shop's move from PHP 7.3 to 7.4.33 is a runtime upgrade. Some apps are built on the newest PHP, some are still on older ones, and some instances run an older app version than their app's newest.

Open **Runtimes → ecs-service-php7** in Massdriver to see the rollout.

## The runtime

`ecs-service-php7` is the catalog's `ecs-service` with PHP's defaults: Apache on port 80. It has no IaC of its own. `deploy.sh runtimes` assembles each version from `bundles/ecs-service` and [runtimes/ecs-service-php7](runtimes/ecs-service-php7) at publish time, so it always runs the same code as every other ECS app, and a fix to `ecs-service` reaches it on the next publish.

Its version is the PHP version. An app built on `7.4.33` gets `PHP_VERSION=7.4.33`, and its image is built `FROM php:7.4.33-apache`. [runtimes.txt](runtimes.txt) lists the versions to publish. A PHP 8 runtime would be another directory next to it, `ecs-service-php8`, and shows on its own runtime page.

## The fleet

| App | Versions published (PHP) | Instance runs |
|---|---|---|
| storefront | 1.3.0 (7.3.33), 1.4.0 (7.4.33) | 1.4.0, on the latest PHP |
| checkout | 2.0.0 (7.4.30), 2.1.0 (7.4.33) | 2.0.0, one version behind its app |
| inventory | 0.9.0 (7.4.33) | 0.9.0, on the latest PHP |
| accounts | 1.2.0 (7.4.30) | 1.2.0, one runtime version behind |
| search | 0.5.0 (7.3.33), 0.6.0 (7.4.30) | 0.5.0, one version behind its app |
| reviews | 0.3.0 (7.4.30) | 0.3.0, one runtime version behind |
| admin | 3.0.0 (7.3.33) | 3.0.0, two runtime versions behind |

The runtime page then shows 2 of 7 instances on the latest version (7.4.33), 3 on 7.4.30 and 2 on 7.3.33. [versions.txt](versions.txt) holds this table; change it to tell a different story.

Every service is a PHP Apache page at `https://<app>.<dev zone>`, on the platform's dev cluster, with the smallest Fargate task on Spot. About $20 a month for all seven.

## Publish order

Versions are published in table order: every runtime version in `runtimes.txt` from oldest to newest, then each app version in `versions.txt`. Each app version is built on the exact runtime version its row names, so an older app version stays on older PHP after a newer runtime is out.

The picture needs stable versions. The runtime page treats the newest stable version as latest, and a development release shows as `7.4.33-dev.<timestamp>`. With `DEV=1`, everything publishes as development releases: the versions spread the same way, but there is no latest version and no "N of 7" line.

## Stand it up

Needs the [telehealth example](../telehealth)'s platform deployed to dev in the same organization, and AWS CLI credentials for its account.

```bash
cd examples/php-fleet
./deploy.sh all
```

That creates the `phpfleet` project with its dev environment, publishes the runtime versions and every app version, builds an image for each PHP version and deploys each instance on its version.

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

This decommissions the instances and destroys the project, the runtime and the app bundles. Tear this down before the telehealth example's platform; the services hold rules on its load balancer and records in its zone.
