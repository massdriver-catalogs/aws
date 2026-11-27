ARG PHP_VERSION=7.4.33
# Amazon's mirror of the official images only carries PHP 7.1 and newer;
# older releases come straight from Docker Hub.
ARG BASE=public.ecr.aws/docker/library/php
FROM ${BASE}:${PHP_VERSION}-apache
COPY index.php /var/www/html/
EXPOSE 80
