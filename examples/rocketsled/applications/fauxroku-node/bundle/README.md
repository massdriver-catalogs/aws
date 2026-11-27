# Fauxroku Node.js Dynos

The web process of a Fauxroku Node.js app. It runs the app's image on Fargate behind the platform's load balancer and answers at `https://<subdomain>.<platform domain>`. Until it has an image it runs nginx, so the address works from the first deploy.

## Build the image with a buildpack

No Dockerfile needed. Paketo's Node.js buildpack reads `package.json`; `npm start` becomes the web process. A `Procfile` line like `web: node server.js` sets the command.

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
| Node.js defaults | always: NODE_ENV=production |
| `DATABASE_URL`, `PGPASSWORD` | Postgres is connected. The URL has no password; libpq clients read `PGPASSWORD`. |
| `REDIS_URL` | Key-Value Store is connected (`rediss://`, TLS) |

Size, count, Spot and scaling are the ECS service runtime's params.
