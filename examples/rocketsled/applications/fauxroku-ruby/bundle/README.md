# Fauxroku Ruby Dynos

The web process of a Fauxroku Ruby app. It runs the app's image on Fargate behind the platform's load balancer and answers at `https://<subdomain>.<platform domain>`. Until it has an image it runs nginx, so the address works from the first deploy.

## Build the image with a buildpack

No Dockerfile needed. Paketo's Ruby buildpack reads `Gemfile.lock` and runs `bundle exec rackup` or `rails server`. A `Procfile` line like `web: bundle exec puma -C config/puma.rb` sets the command.

```bash
pack build "$REGISTRY:$(git rev-parse --short HEAD)" --builder paketobuildpacks/builder-jammy-base \
  --platform linux/arm64 --publish
```

`$REGISTRY` is the URL of the template's Image Repository. A Dockerfile works too; build it for **arm64** unless **Architecture** says otherwise.

## What every dyno gets

| Variable | Set when |
|---|---|
| `PORT` | always; listen on it |
| `PROCESS_TYPE` | always: `web` |
| Ruby defaults | always: RACK_ENV and RAILS_ENV=production, logs to stdout, static files served by the app |
| `DATABASE_URL`, `PGPASSWORD` | Postgres is connected. The URL has no password; libpq clients read `PGPASSWORD`. |
| `REDIS_URL` | Key-Value Store is connected (`rediss://`, TLS) |

Size, count, Spot and scaling are the ECS service runtime's params.
