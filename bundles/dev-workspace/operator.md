---
templating: mustache
---
# Developer Workspace

**Get in:**

```bash
TASK=$(aws ecs list-tasks --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --service-name {{params.md_metadata.name_prefix}} --query 'taskArns[0]' --output text)
aws ecs execute-command --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --task $TASK --container workspace --interactive --command "workspace shell"
```

- **Size:** {{params.size}} ({{params.architecture}}){{#params.spot}}, Spot{{/params.spot}}
- **Cluster:** `{{dependencies.cluster.name}}`, {{dependencies.cluster.region}}
- **Acts as:** the Massdriver service account `{{params.md_metadata.name_prefix}}`
- **Git identity:** {{#params.git_name}}{{params.git_name}}{{#params.git_email}}, {{params.git_email}}{{/params.git_email}}{{/params.git_name}}{{^params.git_name}}not set{{/params.git_name}}
- **Ports open to the VPC:** {{#params.vpn_ports}}`{{.}}` {{/params.vpn_ports}}{{^params.vpn_ports}}none{{/params.vpn_ports}}
- **Home directory backups:** {{#params.home_backups}}on{{/params.home_backups}}{{^params.home_backups}}off{{/params.home_backups}}
- **Logs:** `/ecs/{{params.md_metadata.name_prefix}}`, days kept: {{params.log_retention_days}}

## Get in

You need AWS credentials for this account and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). Then run the **Get in** command.

You land in `/home/dev` as `dev`. `claude`, `opencode`, `mass`, `git` and `mise` are on the PATH. `mass` and the Massdriver MCP server are signed in as the service account `{{params.md_metadata.name_prefix}}`.

Start `tmux` first. If the session drops, run the command again and `tmux attach`.

## Over the VPN

The Developer VPN in this sandbox puts your laptop in the same VPC. It doesn't give you a shell; use ECS Exec for that. It lets your browser reach a dev server running in the workspace, on a port in **Ports open to the VPC** ({{#params.vpn_ports}}`{{.}}` {{/params.vpn_ports}}{{^params.vpn_ports}}none yet: add one and deploy{{/params.vpn_ports}}). The dev server must listen on `0.0.0.0`, not `localhost`.

The workspace's private IP:

```bash
aws ecs describe-tasks --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} --tasks $TASK \
  --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' --output text
```

## `execute-command` fails

- **`The execute command failed because execute command was not enabled`**: the task started before the deploy that enabled it. Force a new task (below).
- **`SessionManagerPlugin is not found`**: install the Session Manager plugin on the laptop.
- **`AccessDeniedException`**: your AWS credentials need `ecs:ExecuteCommand` on the cluster.
- **`TargetNotConnectedException`**: the task can't reach Session Manager. It needs internet egress or SSM VPC endpoints. Check the task is running (below).

## The workspace won't start

```bash
aws ecs describe-services --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --services {{params.md_metadata.name_prefix}} --query 'services[0].events[:10].[createdAt,message]' --output text
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 1h
```

- **`CannotPullContainerError`**: the image is gone from the codebase's repository, usually removed by its lifecycle rule. Push a new image and deploy.
- **`exec format error`**: the image is built for the wrong CPU. Rebuild for **{{params.architecture}}**.
- **`ResourceInitializationError: failed to invoke EFS utils`** or **`mount.nfs4: Connection timed out`**: the task can't reach the home directory. Deploy again; it rewrites the mount targets and security groups.
- **Exit code 137** or `OutOfMemoryError`: raise **Workspace size**.
- **The log stops at `installing ...`**: a tool in **Extra tools** is slow or failing. Remove it and deploy.

## Restart it

Open shells and running programs are lost; the home directory stays.

```bash
aws ecs update-service --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --service {{params.md_metadata.name_prefix}} --force-new-deployment
```

{{#params.spot}}
On Spot, AWS can stop the workspace with two minutes' notice. ECS starts a new one by itself.
{{/params.spot}}

## `mass` says unauthorized or forbidden

- **`401` / `unauthorized`**: the service account's token was deleted. Decommission and deploy again to make a new one. The home directory is deleted too, so push your work first.
- **`forbidden`**: the service account's groups don't allow it. Change **Massdriver groups** and deploy.
