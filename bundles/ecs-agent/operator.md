---
templating: mustache
---
# ECS Agent: {{params.service_account_name}}

## What is it doing right now?

Each run's transcript is in the log, one JSON line per step:

```bash
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 30m --follow
```

Just what it said, without the tool calls:

```bash
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 2h --format short \
  | sed 's/^[^{]*//' | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text'
```

Lines that start with `agent:` come from the loop: a run starting, a run ending with an error, the wait before the next.

## Stop it now

The agent acts with its service account's permissions. Taking them away stops it at once, even mid-run:

```bash
mass instance deploy {{id}} --patch '.groups = []' -m "Stop {{params.service_account_name}}" --follow
```

To stop the task as well, decommission the instance. That deletes the service account too.

## Read its notes

The agent keeps its memory between runs in `~/NOTES.md`. A new task starts with it empty.

```bash
TASK=$(aws ecs list-tasks --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --service-name {{params.md_metadata.name_prefix}} --query 'taskArns[0]' --output text)
aws ecs execute-command --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --task $TASK --container agent --interactive --command "cat /home/agent/NOTES.md"
```

Swap the command for `bash` to look around as the agent: `mass`, `mcp-server`, `claude` and the troubleshooting tools are on the PATH, signed in the same way.

## Runs keep failing

Find the error in the log, above.

- **`Credit balance is too low`** or **`invalid x-api-key`**: the Anthropic key is wrong or out of credit. Set a new one in the `ANTHROPIC_API_KEY` secret and deploy.
- **The run stops early, saying it reached its budget**: the run hit **Most spent per run** (now ${{params.budget_per_run_usd}}). Raise it, or narrow the **Goal**.
- **`401` or `unauthorized` from Massdriver**: the service account's token is gone, for example deleted in **Settings → Service Accounts**. Decommission the instance and deploy it again; that makes a new service account with a new token.
- **`forbidden`** or **`not allowed`**: its groups don't allow what it tried. Its notes say what it needed. Give the group that action, or narrow the goal.
- **An MCP server fails to start**: the command isn't installed. Add its runtime to **Extra tools**, like `node@22` for `npx`.

## The task won't start

```bash
aws ecs describe-services --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} --services {{params.md_metadata.name_prefix}} \
  --query 'services[0].events[:10].[createdAt,message]' --output text
```

- **`CannotPullContainerError`**: the cluster can't pull **Agent image** (`{{params.image_uri}}`). Check the tag exists. For ECR, connect the codebase that owns the repository.
- **`exec format error`**: the image is built for the wrong CPU. Rebuild for **{{params.architecture}}**.
- **`ResourceInitializationError: unable to pull secrets`**: the VPC has no egress, or the secret was deleted. Deploy again to write it back.
- **Exit code 137** or `OutOfMemoryError`: raise **Task size**. Big MCP servers and mise tools use memory.

{{^params.action_sync.enabled}}
## Watch what it does

Turn on **Send actions** with the URL of something that keeps and alerts on what it receives. The destination only sends events whose actor is this agent's service account, so the stream is exactly the agent's changes. Without a receiver, create one by hand that keeps the agent's deploys and proposals and drops the rest:

```bash
mass event destination create \
  --name "{{params.md_metadata.name_prefix}}-watch" \
  --url https://<your receiver>/massdriver \
  --event-type 'deployment.*' --event-type 'instance.*' --event-type 'group_membership.*' \
  --condition '.data.actor.name == "{{params.service_account_name}}"'
```

Alert on `deployment.proposed` and `deployment.started` in prod, and on any `group_membership.*` event: the agent should never change its own groups.
{{/params.action_sync.enabled}}

{{#params.action_sync.enabled}}
## The webhook gets nothing

Events go to `{{params.action_sync.url}}` only for things the agent did. If it hasn't changed anything, nothing is sent. Check the destination in **Settings → Event Destinations**, `{{params.md_metadata.name_prefix}}-actions`: Massdriver pauses one when sends fail for a day, and the next deploy of this instance resumes it.

The receiver checks each request with the signing secret:

```bash
aws secretsmanager list-secrets --region {{dependencies.cluster.region}} \
  --filters Key=name,Values={{params.md_metadata.name_prefix}}-actions- --query 'SecretList[0].ARN' --output text
aws secretsmanager get-secret-value --region {{dependencies.cluster.region}} --secret-id <arn> --query SecretString --output text
```
{{/params.action_sync.enabled}}
