---
templating: mustache
---
# Developer VPN

{{#resources.tunnel}}
## Connect

Download `wg0.conf` from the **tunnel** resource, then import it into the WireGuard app, or:

```bash
sudo wg-quick up ./wg0.conf
```

Keep the file private. Anyone with it is inside the VPC.

## The tunnel is up but nothing answers

Check for a handshake first:

```bash
sudo wg show
```

- **No `latest handshake` line:** the laptop can't reach the server on UDP 51820. Guest and hotel networks often block it. Try another network, or check **Allowed laptop networks** includes the laptop's public IP (`curl -s https://checkip.amazonaws.com`).
- **Handshake, but a database or cache times out:** its security group does not allow the VPN server. Find the server's group and add it to the target's rules:

  ```bash
  aws ec2 describe-security-groups --region {{dependencies.network.region}} \
    --filters Name=group-name,Values={{params.md_metadata.name_prefix}} --query 'SecurityGroups[].GroupId' --output text
  ```

- **Handshake, but hostnames don't resolve:** another VPN or a local DNS setting is overriding the tunnel's DNS. Disconnect the other VPN, or look up the host with `dig @<DNS from wg0.conf> <hostname>`.

## The server itself

Open a shell on it with Session Manager; there is no SSH:

```bash
id=$(aws ec2 describe-instances --region {{dependencies.network.region}} \
  --filters Name=tag:Name,Values={{params.md_metadata.name_prefix}} Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text)
aws ssm start-session --region {{dependencies.network.region}} --target "$id"
sudo wg show
sudo journalctl -u wg-quick@wg0 --no-pager | tail -20
sudo tail -50 /var/log/cloud-init-output.log
```

If `wg-quick@wg0` never started, the setup log shows why, usually a failed package install.

## Revoke access

Decommission this deployment. The server and every key are deleted, so a copied `wg0.conf` is useless. Redeploying makes new keys, and the developer downloads a new `wg0.conf`.
{{/resources.tunnel}}
{{^resources.tunnel}}
Deploy to create the tunnel.
{{/resources.tunnel}}
