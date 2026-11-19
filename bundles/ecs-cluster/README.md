# ECS Cluster

A Fargate cluster for an environment, and one internet-facing load balancer that all of its services share. Services run on Fargate or Fargate Spot; there are no servers to manage.

## What it needs

- **A VPC** with public subnets in at least two availability zones. The load balancer goes there.
- **A DNS zone** (optional). With one, the load balancer serves HTTPS on port 443 with the zone's certificate, and port 80 redirects to HTTPS. The zone's certificate must be in the same region as the VPC.

Without a DNS zone, the load balancer serves plain HTTP on port 80 only. Production should have a zone.

## How services use it

Each service adds a rule to the load balancer for its own name, like `api.dev.example.com`, and a DNS record pointing that name at the load balancer. A request for a name no service has claimed gets a 404.

Connecting a DNS zone later moves services from the HTTP listener to the HTTPS one. Redeploy each service afterwards so its rule moves too.

## Cost

The load balancer costs about **$16/month** plus a charge for traffic (LCUs). The cluster itself is free; services pay for their own tasks.

## Decommissioning

Decommission every service in the cluster first. With **Deletion protection** on, turn it off and deploy before decommissioning. Access logs are deleted with the cluster.
