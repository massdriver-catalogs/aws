---
templating: mustache
---
# MariaDB

{{#resources.database}}
- **Endpoint:** `{{resources.database.hostname}}:{{resources.database.port}}`, database `{{resources.database.database}}`, user `{{resources.database.username}}`
- **Region:** {{resources.database.region}}
{{/resources.database}}
- **Version:** MariaDB {{params.engine_version}}
- **Size:** {{params.instance_class}}, {{params.storage_gb}} GB storage{{#params.multi_az}}, Multi-AZ{{/params.multi_az}}
{{#dependencies.network}}
- **VPC:** `{{dependencies.network.id}}`
{{/dependencies.network}}
- **Backups:** days kept: {{params.backup_retention_days}}
- **Deletion protection:** {{#params.deletion_protection}}on{{/params.deletion_protection}}{{^params.deletion_protection}}off{{/params.deletion_protection}}

{{#resources.database}}
## Connect with the mariadb client

The database has no public address and there is no bastion host. Use one of these.

**CloudShell in the VPC (no app needed).** In the AWS console, open CloudShell in **{{resources.database.region}}**, choose **Create VPC environment**, and pick:

- VPC: `{{dependencies.network.id}}`
- A **private** subnet. Internal subnets have no internet access, so the client can't be installed there. The VPC needs internet egress.
- Security groups: `{{resources.database.client_security_group_id}}`, which lets you reach the database, and a temporary one for the internet. Make the temporary one first:

  ```bash
  aws ec2 create-security-group --region {{resources.database.region}} --vpc-id {{dependencies.network.id}} \
    --group-name {{id}}-cloudshell --description "CloudShell outbound" --query GroupId --output text
  ```

Then:

```bash
sudo dnf install -y mariadb105
export MYSQL_PWD=$(aws secretsmanager get-secret-value --region {{resources.database.region}} \
  --secret-id {{resources.database.secret_arn}} --query SecretString --output text | jq -r .password)
mysql --ssl -h {{resources.database.hostname}} -P {{resources.database.port}} -u {{resources.database.username}} {{resources.database.database}}
```

Delete the VPC environment and the `{{id}}-cloudshell` security group when you're done. While the environment exists, it can reach the database.

**From a running ECS task.** If an app task already has the client group and ECS Exec turned on, open a shell in it. The mysql client is only there if the app image has it.

```bash
aws ecs execute-command --region {{resources.database.region}} --cluster <cluster> --task <task-id> \
  --container <container> --interactive --command "/bin/sh"
```

## App can't connect

- **Timeout:** the app doesn't have the client security group. Check what's attached to its network interfaces:

  ```bash
  aws ec2 describe-network-interfaces --region {{resources.database.region}} \
    --filters Name=group-id,Values={{resources.database.client_security_group_id}} \
    --query 'NetworkInterfaces[].[Description,PrivateIpAddress]' --output table
  ```

  If the app isn't listed, connect it to this database in Massdriver and redeploy it.

- **`Access denied for user`:** the app has an old password. The password changed (see below); restart or redeploy the app so it reads the new one.
- **`Connections using insecure transport are prohibited`:** the app isn't using TLS. Turn on SSL in its driver settings.
- **`AccessDeniedException` reading the secret:** the app's role doesn't have the **read-secret** policy:

  ```bash
{{#resources.database.policies}}
  aws iam list-entities-for-policy --policy-arn {{arn}} --query 'PolicyRoles[].RoleName'   # {{name}}
{{/resources.database.policies}}
  ```

## Change the password

Raise **Password version** by one and deploy. The database, the secret and this resource get the new password in the same deploy. Then redeploy every app connected to this database, or restart the ones that read the secret at start-up. Until then they fail with `Access denied for user`.

Don't change the password with `ALTER USER` or the RDS console. The secret and resource keep the old one, so every app breaks.

## Restore data

Restores always make a **new** database next to this one. Copy what you need back into the live one; this bundle keeps managing `{{resources.database.id}}`.

```bash
REGION={{resources.database.region}}
DB={{resources.database.id}}
SG=$(aws rds describe-db-instances --region $REGION --db-instance-identifier $DB \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)
PARAMS=$(aws rds describe-db-instances --region $REGION --db-instance-identifier $DB \
  --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' --output text)

# Restorable window:
aws rds describe-db-instances --region $REGION --db-instance-identifier $DB \
  --query 'DBInstances[0].LatestRestorableTime'

# To a point in time (UTC), within the last {{params.backup_retention_days}} days:
aws rds restore-db-instance-to-point-in-time --region $REGION \
  --source-db-instance-identifier $DB --target-db-instance-identifier $DB-restored \
  --restore-time <YYYY-MM-DDTHH:MM:SSZ> \
  --db-subnet-group-name $DB --vpc-security-group-ids $SG --db-parameter-group-name $PARAMS \
  --no-publicly-accessible

# Or from a snapshot:
aws rds describe-db-snapshots --region $REGION --db-instance-identifier $DB \
  --query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime]' --output table
aws rds restore-db-instance-from-db-snapshot --region $REGION \
  --db-snapshot-identifier <snapshot-id> --db-instance-identifier $DB-restored \
  --db-subnet-group-name $DB --vpc-security-group-ids $SG --db-parameter-group-name $PARAMS \
  --no-publicly-accessible
```

The restored database has the password the original had at that time. Wait for it, get its hostname, connect to it as above, then copy tables across:

```bash
aws rds wait db-instance-available --region $REGION --db-instance-identifier $DB-restored
aws rds describe-db-instances --region $REGION --db-instance-identifier $DB-restored \
  --query 'DBInstances[0].Endpoint.Address' --output text
```

```bash
mysqldump --ssl -h <restored-host> -u {{resources.database.username}} --no-create-info \
  {{resources.database.database}} <table> | mysql --ssl -h {{resources.database.hostname}} -u {{resources.database.username}} {{resources.database.database}}
```

Delete the restored database when you're done:

```bash
aws rds delete-db-instance --region $REGION --db-instance-identifier $DB-restored --skip-final-snapshot
```

## Storage is full

Writes fail with `The table ... is full` or `Errcode: 28 "No space left on device"`.

```bash
aws cloudwatch get-metric-statistics --region {{resources.database.region}} --namespace AWS/RDS \
  --metric-name FreeStorageSpace --dimensions Name=DBInstanceIdentifier,Value={{resources.database.id}} \
  --start-time $(date -u -v-6H +%FT%TZ 2>/dev/null || date -u -d '-6 hours' +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) --period 600 --statistics Minimum --output table
```

{{#params.storage_max_gb}}
Storage grows on its own up to {{params.storage_max_gb}} GB, but only once every six hours. If it's at the limit or waiting, raise **Storage (GB)** and deploy; that applies straight away.
{{/params.storage_max_gb}}
{{^params.storage_max_gb}}
Automatic growth is off. Raise **Storage (GB)** and deploy; that applies straight away.
{{/params.storage_max_gb}}

After any resize, RDS waits six hours before the next one. Find what is using space:

```sql
SELECT table_schema, table_name, ROUND((data_length + index_length) / 1024 / 1024) AS mb
FROM information_schema.tables ORDER BY data_length + index_length DESC LIMIT 10;
```

## Too many connections

Apps get `Too many connections` (error 1040). The limit depends on instance memory: about 60 on db.t4g.micro, rising with larger sizes.

```sql
SHOW VARIABLES LIKE 'max_connections';
SELECT user, SUBSTRING_INDEX(host, ':', 1) AS client, command, COUNT(*) FROM information_schema.processlist
GROUP BY 1, 2, 3 ORDER BY 4 DESC;
```

- Many `Sleep` connections from one app: its pool is too big for its number of tasks. Pool size × tasks must stay under the limit.
- Close a stuck session: find its `id` in `SHOW PROCESSLIST;`, then `CALL mysql.rds_kill(<id>);`
- If the app really needs more, pick a larger **Instance size** and deploy.

## Upgrade to a new major version

1. Check that the app works with the new version, ideally on a copy restored from a snapshot.
2. Take a snapshot so you can go back:

   ```bash
   aws rds create-db-snapshot --region {{resources.database.region}} \
     --db-instance-identifier {{resources.database.id}} --db-snapshot-identifier {{resources.database.id}}-pre-upgrade
   ```

3. Pick the new **MariaDB version** and deploy. The database is down for several minutes, longer for big databases. Multi-AZ doesn't avoid this.

If the upgrade fails, RDS leaves the database on the old version and says why in its events:

```bash
aws rds describe-events --region {{resources.database.region}} --source-type db-instance \
  --source-identifier {{resources.database.id}} --duration 1440 --query 'Events[].Message'
```

Fix what the pre-upgrade check names, often tables using removed features, and deploy again. You can't go back to an older version in place; restore the pre-upgrade snapshot into a new database instead.

## Decommission fails

**Deletion protection** is on. Turn it off, deploy, then decommission.
{{/resources.database}}
