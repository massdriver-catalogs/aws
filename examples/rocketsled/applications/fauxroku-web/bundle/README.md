# Fauxroku Web Dynos

The web process of a Fauxroku app. It runs the customer's container image on Fargate behind the platform's load balancer and answers at `https://<subdomain>.<platform domain>`. Until it has an image it runs nginx, so the address works from the first deploy.

Every dyno gets:

| Variable | Set when |
|---|---|
| `PORT` | always; listen on it |
| `PROCESS_TYPE` | always: `web` |
| `DATABASE_URL`, `PGPASSWORD` | Postgres is connected. The URL has no password; libpq clients read `PGPASSWORD`. |
| `REDIS_URL` | Key-Value Store is connected (`rediss://`, TLS) |

Size, count, Spot and scaling are the ECS service runtime's params. Build images for **arm64** unless **Architecture** says otherwise.
