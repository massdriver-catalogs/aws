---
templating: mustache
---
# ECS Cluster

{{#resources.cluster}}
## 5xx from the load balancer

Find out who sent it: the load balancer itself, or a service behind it.

```bash
LB={{resources.cluster.load_balancer.arn}}
DIM=$(echo $LB | sed 's|.*:loadbalancer/||')
for m in HTTPCode_ELB_5XX_Count HTTPCode_Target_5XX_Count; do
  echo "$m"; aws cloudwatch get-metric-statistics --region {{resources.cluster.region}} --namespace AWS/ApplicationELB \
    --metric-name $m --dimensions Name=LoadBalancer,Value=$DIM \
    --start-time $(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '-1 hour' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
    --period 300 --statistics Sum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Sum]' --output text
done
```

- **Target 5xx:** the app returned the error. Read that service's logs.
- **502:** the app closed the connection or sent a bad response. Often the app crashed mid-request, or its keep-alive timeout is shorter than the load balancer's 60 seconds.
- **503:** the rule matched but the service has no healthy tasks. See that service's guide, "Unhealthy targets".
- **504:** the app took longer than 60 seconds to answer.

Find which services have no healthy targets:

```bash
for tg in $(aws elbv2 describe-target-groups --region {{resources.cluster.region}} --load-balancer-arn {{resources.cluster.load_balancer.arn}} --query 'TargetGroups[].TargetGroupArn' --output text); do
  echo "$tg"; aws elbv2 describe-target-health --region {{resources.cluster.region}} --target-group-arn $tg \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text
done
```

{{#params.access_logs}}
Access logs land in the bucket within 5 minutes. Find the failing requests:

```bash
BUCKET=$(aws elbv2 describe-load-balancer-attributes --region {{resources.cluster.region}} --load-balancer-arn {{resources.cluster.load_balancer.arn}} \
  --query "Attributes[?Key=='access_logs.s3.bucket'].Value" --output text)
aws s3 ls s3://$BUCKET/AWSLogs/ --recursive | tail -5
aws s3 cp s3://$BUCKET/<key> - | gunzip | awk '$9 ~ /^5/'
```
{{/params.access_logs}}

## A name returns 404

The load balancer answered but no rule matched the name. List the rules:

```bash
aws elbv2 describe-rules --region {{resources.cluster.region}} --listener-arn {{resources.cluster.load_balancer.listener_arn}} \
  --query 'Rules[].[Priority,Conditions[0].HostHeaderConfig.Values[0]]' --output text
```

- **Name missing:** the service has no **Subdomain**, or its last deploy failed. Redeploy it.
- **Rule is on the wrong listener:** a DNS zone was connected to the cluster after the service deployed. Redeploy the service.

## Requests get a 403
{{#params.waf}}

The firewall blocked them. See which rule and what the request looked like:

```bash
aws logs filter-log-events --log-group-name aws-waf-logs-{{params.md_metadata.name_prefix}} --region {{dependencies.network.region}} \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) --query 'events[].message' --output json \
  | jq -r '.[] | fromjson | .terminatingRuleId + "  " + .httpRequest.httpMethod + " " + .httpRequest.uri'
```

If a rule blocks real traffic, like a large upload tripping the body size rule, turn off **Block common attacks** and deploy while you plan an exception.
{{/params.waf}}
{{^params.waf}}

The firewall is off, so a 403 comes from the service itself. Check its logs.
{{/params.waf}}

## Certificate or HTTPS errors

{{#dependencies.dns}}
```bash
aws acm describe-certificate --region {{resources.cluster.region}} --certificate-arn {{dependencies.dns.certificate_arn}} \
  --query 'Certificate.[Status,NotAfter,SubjectAlternativeNames]'
curl -sv https://<subdomain>.{{dependencies.dns.domain}} -o /dev/null 2>&1 | grep -E 'subject|expire|SSL'
```

- **Status not `ISSUED`:** the certificate's DNS validation records are missing. Fix them in the DNS zone.
- **Name not covered:** the certificate covers `{{dependencies.dns.domain}}` and `*.{{dependencies.dns.domain}}` only. `a.b.{{dependencies.dns.domain}}` won't work.
- **Old clients fail the handshake:** the listener needs TLS 1.2 or newer. That's intended.
{{/dependencies.dns}}
{{^dependencies.dns}}
No DNS zone is connected, so there is no HTTPS listener. Connect a DNS zone in the same region, deploy the cluster, then redeploy every service.
{{/dependencies.dns}}

## Deploys hang or tasks take long to stop

When a task stops, the load balancer finishes its open requests first, for up to 30 seconds. Check what is draining:

```bash
for tg in $(aws elbv2 describe-target-groups --region {{resources.cluster.region}} --load-balancer-arn {{resources.cluster.load_balancer.arn}} --query 'TargetGroups[].TargetGroupArn' --output text); do
  aws elbv2 describe-target-health --region {{resources.cluster.region}} --target-group-arn $tg \
    --query "TargetHealthDescriptions[?TargetHealth.State=='draining'].[Target.Id,Target.Port]" --output text
done
```

Long-lived connections (websockets, streaming) hold a target in `draining` until the timeout ends. That's normal. Draining for many minutes means the deploy is stuck on something else; see the service's guide.

## Decommission fails

{{#params.deletion_protection}}
**Deletion protection** is on. Turn it off, deploy, then decommission.
{{/params.deletion_protection}}

- **`ResourceInUse` on the security group or load balancer:** a service still uses it. Decommission the services in this cluster first:

```bash
aws ecs list-services --region {{resources.cluster.region}} --cluster {{resources.cluster.name}}
```
{{/resources.cluster}}
