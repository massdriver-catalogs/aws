---
templating: mustache
---
# DNS Zone

## Delegate a new zone

A new zone answers nothing until its parent points to it. Get its name servers:

```bash
aws route53 list-hosted-zones-by-name --dns-name {{params.domain}} \
  --query "HostedZones[?Name=='{{params.domain}}.'] | [0].Id" --output text \
  | xargs -I{} aws route53 get-hosted-zone --id {} --query 'DelegationSet.NameServers' --output text
```

Add them as an `NS` record named `{{params.domain}}` in the parent zone. If the parent is in Route 53:

```bash
PARENT_ZONE_ID=<parent zone id>
aws route53 change-resource-record-sets --hosted-zone-id "$PARENT_ZONE_ID" --change-batch '{
  "Changes": [{"Action": "UPSERT", "ResourceRecordSet": {
    "Name": "{{params.domain}}", "Type": "NS", "TTL": 300,
    "ResourceRecords": [{"Value": "<ns-1>"}, {"Value": "<ns-2>"}, {"Value": "<ns-3>"}, {"Value": "<ns-4>"}]
  }}]
}'
```

If `{{params.domain}}` is a domain you registered, set the name servers at the registrar instead.

Check the delegation from outside:

```bash
dig NS {{params.domain}} +short
dig NS {{params.domain}} +trace | tail -n 8
```

Both must list the same four `awsdns` name servers. If `+short` returns nothing or different servers, the parent record is missing, has a typo, or points at an older zone with the same name.

## Finish DNSSEC

With **Sign the zone (DNSSEC)** on, Route 53 signs the zone, but resolvers only check the signatures once the parent has a `DS` record for it. Get the record:

{{#resources.zone}}
```bash
aws route53 get-dnssec --hosted-zone-id {{resources.zone.zone_id}} --query 'KeySigningKeys[0].DSRecord' --output text
```
{{/resources.zone}}

If the parent is in Route 53, add it next to the `NS` record:

```bash
aws route53 change-resource-record-sets --hosted-zone-id "$PARENT_ZONE_ID" --change-batch '{
  "Changes": [{"Action": "UPSERT", "ResourceRecordSet": {
    "Name": "{{params.domain}}", "Type": "DS", "TTL": 3600,
    "ResourceRecords": [{"Value": "<DSRecord>"}]
  }}]
}'
```

For a domain you registered, add it at the registrar. Check it:

```bash
dig DS {{params.domain}} +short
dig @1.1.1.1 {{params.domain}} SOA +dnssec | grep flags
```

The second command shows `ad` in the flags once a validating resolver trusts the answer. `SERVFAIL` means the `DS` record doesn't match the zone's key.

**Turning it off:** delete the `DS` record first and wait for its TTL (a day at most registrars). Turning signing off while the parent still has the `DS` record makes the whole domain fail to resolve.

## Deploy timed out waiting for the certificate

The error is `waiting for ACM Certificate ... to be issued: timeout`. The zone and certificate exist; only the wait failed. Look at the certificate:

```bash
aws acm list-certificates --region {{params.region}} --certificate-statuses PENDING_VALIDATION ISSUED FAILED \
  --query "CertificateSummaryList[?DomainName=='{{params.domain}}'].[CertificateArn,Status]" --output table
aws acm describe-certificate --region {{params.region}} --certificate-arn <arn> \
  --query 'Certificate.DomainValidationOptions[].[DomainName,ValidationStatus,ResourceRecord.Name,ResourceRecord.Value]' --output table
```

Check the validation record from the internet:

```bash
dig CNAME <ResourceRecord.Name> +short
```

- **No answer:** the zone isn't delegated yet. Do **Delegate a new zone**, wait for `dig NS` to show the right servers, then redeploy.
- **Answer matches `ResourceRecord.Value`:** ACM checks every few minutes. Redeploy; it picks up the issued certificate.
- **Status `FAILED`:** usually a `CAA` record on the domain or a parent that doesn't allow Amazon. Check `dig CAA {{params.domain}} +short` and its parents. Add `0 issue "amazon.com"` where a `CAA` record exists, then delete the failed certificate and redeploy. The deploy requests a new one.

  ```bash
  aws acm delete-certificate --region {{params.region}} --certificate-arn <arn>
  ```

## Add a record by hand

Use this for one-off names outside Massdriver, such as a mail or verification record. Don't edit records other bundles made, or the `_`-prefixed validation record.

{{#resources.zone}}
```bash
aws route53 change-resource-record-sets --hosted-zone-id {{resources.zone.zone_id}} --change-batch '{
  "Changes": [{"Action": "UPSERT", "ResourceRecordSet": {
    "Name": "<name>.{{resources.zone.domain}}", "Type": "TXT", "TTL": 300,
    "ResourceRecords": [{"Value": "\"<value>\""}]
  }}]
}'
```

Check it from the zone's own name servers, which skips caches:

```bash
dig TXT <name>.{{resources.zone.domain}} +short \
  @$(aws route53 get-hosted-zone --id {{resources.zone.zone_id}} --query 'DelegationSet.NameServers[0]' --output text)
```

To remove the record, run the same command with `"Action": "DELETE"` and the exact same values.
{{/resources.zone}}

## Certificate not renewing

The alarm fires when the certificate has less than 30 days left. ACM renews it 60 days before expiry, but only if the validation record still resolves.

{{#resources.zone}}
```bash
aws acm describe-certificate --region {{resources.zone.region}} --certificate-arn {{resources.zone.certificate_arn}} \
  --query 'Certificate.[Status,NotAfter,RenewalSummary.RenewalStatus,RenewalSummary.DomainValidationOptions[].ValidationStatus]'
aws route53 list-resource-record-sets --hosted-zone-id {{resources.zone.zone_id}} \
  --query "ResourceRecordSets[?Type=='CNAME' && starts_with(Name, '_')]"
```
{{/resources.zone}}

- **The `_` CNAME record is gone:** redeploy this bundle. It puts the record back and ACM retries.
- **The record is there but `dig NS {{params.domain}} +short` is empty or wrong:** the delegation in the parent was removed. Do **Delegate a new zone** again.

## Decommission fails with `HostedZoneNotEmpty`

Other records are still in the zone:

{{#resources.zone}}
```bash
aws route53 list-resource-record-sets --hosted-zone-id {{resources.zone.zone_id}} \
  --query "ResourceRecordSets[?Type!='NS' && Type!='SOA'].[Name,Type]" --output table
```
{{/resources.zone}}

Decommission the bundles that own them. Delete records added by hand with the `DELETE` command above. Then decommission again.
