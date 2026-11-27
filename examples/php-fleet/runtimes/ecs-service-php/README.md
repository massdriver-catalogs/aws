# ECS Service (PHP 7)

Runs a PHP 7 app on Fargate, on the cluster's load balancer at `<subdomain>.<zone>`. It is the `ecs-service` runtime with PHP's defaults: Apache on port 80, health checks on `/`.

The runtime's version is the PHP version its apps run. An app built on `7.4.33` builds its image `FROM php:7.4.33-apache` and gets `PHP_VERSION=7.4.33` in its environment. Publishing a new PHP patch as a new runtime version, then republishing each app on it, is how a PHP upgrade rolls out.
