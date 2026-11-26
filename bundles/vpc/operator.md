---
templating: mustache
---
# VPC

- **Region:** {{params.region}}
{{#resources.network}}
- **VPC:** `{{resources.network.id}}`, {{resources.network.cidr}}
{{/resources.network}}
- **Zones:** {{params.zone_count}}
- **Internet egress:** `{{params.egress}}`
- **Interface endpoints:** {{#params.private_endpoints}}`{{.}}` {{/params.private_endpoints}}{{^params.private_endpoints}}none{{/params.private_endpoints}}
- **Flow logs:** `/vpc/{{params.md_metadata.name_prefix}}/flow-logs`, days kept: {{params.flow_log_retention_days}}

## Private subnets lost internet access

Check which egress is in use, then follow that section.

```bash
aws ec2 describe-route-tables --region {{params.region}} \
  --filters Name=tag:Name,Values='{{params.md_metadata.name_prefix}}-private-*' \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`]'
```

No `0.0.0.0/0` route means egress is set to **None**. Workloads then reach only the VPC and its endpoints.

### NAT instance

```bash
aws ec2 describe-instance-status --region {{params.region}} --include-all-instances \
  --filters Name=tag:Name,Values='{{params.md_metadata.name_prefix}}-nat' \
  --query 'InstanceStatuses[].[InstanceId,InstanceState.Name,SystemStatus.Status,InstanceStatus.Status]'
```

- **stopped:** start it. The routes point at its network interface and come back on their own.
- **impaired system status:** auto-recovery should move it to new hardware within minutes. If it doesn't, stop and start it.
- **running and healthy:** connect and check forwarding.

```bash
aws ssm start-session --region {{params.region}} --target <instance-id>
sudo sysctl net.ipv4.ip_forward     # must be 1
sudo iptables -t nat -L POSTROUTING  # must show MASQUERADE
```

If either is missing, terminate the instance and redeploy. The deploy makes a new one and runs the setup again.

### NAT gateway out of ports

The "out of ports" alarm means one destination is getting more than ~55,000 connections at once through one gateway. Find who is opening them:

```bash
aws logs start-query --region {{params.region}} \
  --log-group-name /vpc/{{params.md_metadata.name_prefix}}/flow-logs \
  --start-time $(( $(date +%s) - 3600 )) --end-time $(date +%s) \
  --query-string 'stats count(*) as flows by srcAddr, dstAddr | sort flows desc | limit 20'
```

The usual cause is a client that doesn't reuse connections. Fix the client. Switching to **NAT gateway per zone** spreads the load but doesn't remove the cause.

## Can't reach an AWS API from an internal subnet

Internal subnets have no route out. They reach AWS only through endpoints. List the ones this VPC has:

{{#resources.network}}
```bash
aws ec2 describe-vpc-endpoints --region {{params.region}} \
  --filters Name=vpc-id,Values={{resources.network.id}} \
  --query 'VpcEndpoints[].[ServiceName,VpcEndpointType,State]' --output table
```
{{/resources.network}}

If the service is missing, add it under **Interface endpoints** and redeploy. Otherwise check the caller's security group allows HTTPS (443) out to the VPC range.

## A subnet is running out of addresses

{{#resources.network}}
```bash
aws ec2 describe-subnets --region {{params.region}} \
  --filters Name=vpc-id,Values={{resources.network.id}} \
  --query 'Subnets[].[Tags[?Key==`Name`].Value|[0],CidrBlock,AvailableIpAddressCount]' --output table
```
{{/resources.network}}

Workloads that pick a zone themselves tend to pile into the first one. Spread them across zones first. If every zone is short, the VPC needs a second address range. That changes the layout of this bundle, so plan it rather than doing it at 2am.

## Traffic is being dropped

Flow logs record every rejected connection. Filter by the address that can't connect:

```bash
aws logs start-query --region {{params.region}} \
  --log-group-name /vpc/{{params.md_metadata.name_prefix}}/flow-logs \
  --start-time $(( $(date +%s) - 3600 )) --end-time $(date +%s) \
  --query-string 'filter action="REJECT" and (srcAddr="<ip>" or dstAddr="<ip>") | fields @timestamp, srcAddr, dstAddr, dstPort, protocol | sort @timestamp desc | limit 50'
```

Then read the results:

```bash
aws logs get-query-results --region {{params.region}} --query-id <query-id>
```

Every reject comes from a security group: the receiving workload's group doesn't allow the sender. Fix it in the receiving workload's bundle, not here.

## Decommission fails with `DependencyViolation`

Something still has a network interface in a subnet. Find it:

{{#resources.network}}
```bash
aws ec2 describe-network-interfaces --region {{params.region}} \
  --filters Name=vpc-id,Values={{resources.network.id}} \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,InterfaceType,Description,RequesterId]' --output table
```
{{/resources.network}}

Decommission the bundle that owns it, then try again. Lambda interfaces can take up to 40 minutes to go away after the function is deleted.
