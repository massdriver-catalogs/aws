# MariaDB

One Amazon RDS for MariaDB database for one app, inside the environment's VPC.

## What it needs

- An AWS role to deploy with.
- A VPC. The database goes in the VPC's internal subnets, or in its private subnets if there are no internal ones. It needs subnets in at least two availability zones. The database is in the VPC's region.

## What it makes

- The database instance, encrypted, with automatic minor version upgrades and daily backups.
- Two security groups. The database's own group lets in MariaDB traffic (port 3306) only from the **client** group. The client group has no rules; an app attaches it to reach the database.
- A Secrets Manager secret with the connection details as JSON: `username`, `password`, `engine`, `host`, `port`, `dbname`.
- An IAM policy, **read-secret**, that an app attaches to its role to read that secret.
- CloudWatch log groups for the error log and the slow query log. Queries slower than one second are logged.

## Connecting

Connections must use TLS; the server refuses plain connections. The `mysql` and `mariadb` command-line clients use TLS on their own. Some drivers need it turned on, for example `ssl: {}` in Node's `mysql2`. Use the [RDS certificate bundle](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem) to also check the server.

An app can read the password from the secret at start-up, or receive it from this database's resource when it is deployed. IAM database authentication is also on, for apps that would rather use short-lived tokens than a password.

## Password

The password is 40 random letters and digits, so it is safe in a connection URL without escaping. To change it, raise **Password version** and deploy. The secret and resource update in the same deploy; apps that read the password once must restart or redeploy.

## Versions

Minor versions upgrade on their own in the maintenance window. A major version upgrade happens when you pick a newer **MariaDB version** and deploy; the database is down for several minutes. You can't move to an older version. To go back, restore a snapshot taken before the upgrade into a new database.

## Decommissioning

With **Deletion protection** on, decommissioning fails until you turn it off and deploy. After that, a final snapshot is kept unless **Skip final snapshot** is on. A kept snapshot costs storage until you delete it.
