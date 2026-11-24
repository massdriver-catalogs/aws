# VPC

The network for one environment. Deploy one in each environment and set it as the environment default: every bundle there that needs a network uses it. It is the only bundle that deals with address ranges. Everything else goes into one of its subnets and is kept apart by its own security group.

## What it needs

An AWS IAM role that Massdriver can assume in the target account.

## Subnets

Every availability zone gets three subnets.

| Tier | Size on a /16 | Routes to | For |
|---|---|---|---|
| Private | /19 | The VPC's egress | Most workloads: containers and functions |
| Internal | /21 | Nowhere outside the VPC | Databases, caches, and anything that must never reach the internet |
| Public | /22 | Internet gateway | Load balancers, NAT, and anything with a public IP |

Space is always laid out for three zones, so going from two zones to three later doesn't move any subnet.

S3 and DynamoDB gateway endpoints are attached to every subnet, so that traffic never goes through egress. Turn on **Interface endpoints** to let private and internal subnets reach other AWS APIs, such as ECR and Secrets Manager, without egress.

## Egress

| Option | Cost | Trade-off |
|---|---|---|
| None | — | Private subnets reach only the VPC and its endpoints |
| NAT instance | ~$7/month | A t4g.nano. EC2 auto-recovery restarts it if the host fails; egress pauses until it's back |
| NAT gateway | ~$33/month + $0.045/GB | Managed, but in one zone |
| NAT gateway per zone | ~$33/month each + $0.045/GB | Survives a zone outage |

Changing egress replaces the default route in each private subnet, so private subnets lose internet access for a minute or two during the deploy. If the deploy fails with `RouteAlreadyExists`, deploy again; the old route is gone by then.

## Logs and alarms

Flow logs for every connection go to CloudWatch Logs, encrypted with a key made for this VPC. Alarms fire when a NAT gateway runs out of ports or the NAT instance fails its status checks.

## Ranges across environments

Give each environment a different CIDR. Ranges that overlap can never be peered or connected later.

## Decommissioning

Remove everything that runs in the network first. Deleting the VPC fails while any subnet still has a network interface in it.
