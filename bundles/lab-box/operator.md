---
templating: mustache
---
# Lab Box

{{#resources.lab}}
**URL:** none of its own. People open the lab through Gamelab. Inside the VPC, the agent is at `{{resources.lab.agent_url}}` and the game at `{{resources.lab.game_url}}`.

{{/resources.lab}}
- **Player:** {{params.player_name}}, age {{params.player_age}}
- **Model:** `{{params.model}}`
- **Size:** {{params.size}} CPU/MB, {{#params.spot}}Spot{{/params.spot}}{{^params.spot}}on demand{{/params.spot}}, {{params.architecture}}
- **Service:** `{{params.md_metadata.name_prefix}}` on cluster `{{dependencies.cluster.name}}`, {{dependencies.cluster.region}}
- **Saves & scores:** {{#dependencies.gamedata}}DynamoDB table `{{dependencies.gamedata.name}}`{{/dependencies.gamedata}}{{^dependencies.gamedata}}off{{/dependencies.gamedata}}
- **Sleeps:** when Gamelab sets the service's desired count to 0. A deploy leaves the count as it is.

## The box is asleep

A desired count of 0 is normal: nobody used the lab for 30 minutes, so Gamelab stopped the task. Opening the lab in Gamelab wakes it in about a minute. To wake it by hand:

```bash
aws ecs update-service --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --service {{params.md_metadata.name_prefix}} --desired-count 1 --query 'service.desiredCount'
```

If it never stays up, it isn't sleep: see the next section.

## The box won't start

```bash
aws ecs describe-services --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --services {{params.md_metadata.name_prefix}} --query 'services[0].events[:10].[createdAt,message]' --output text
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 1h
```

- **`LAB_PASSWORD is not set`** in the log, or the deploy failed on **Set the LAB_PASSWORD secret**: the box never runs without one. Gamelab sets it when it makes the lab; press **Try again** on the lab in Gamelab, or set the secret on this instance and deploy.
- **`CannotPullContainerError`**: the image is gone from the codebase's repository. Push a new one (`./bootstrap.sh images` in `examples/gamelab`) and deploy.
- **`exec format error`**: the image is built for the wrong CPU. Rebuild for **{{params.architecture}}**.
- **`ResourceInitializationError: failed to invoke EFS utils`** or **`mount.nfs4: Connection timed out`**: the task can't reach its home directory. Deploy again.
- **Exit code 137** or `OutOfMemoryError`: raise **Box size**.

## The helper answers with an error

The player sees a short message; the real one is in the log (`APIError`).

- **"can't reach Claude"**: the `ANTHROPIC_API_KEY` secret is missing or revoked. Set it on this instance and deploy. New labs copy it from `labs-template-box`, so fix it there too.
- **"out of credit"**: top up the Anthropic account, or raise the key's spend limit.
- **"a bit busy"**: Anthropic rate limits. It passes; a smaller **Claude model** is less likely to hit them.

## The game is blank or old

The game is `~/game/index.html`. Open a shell (below) and look:

```bash
ls -la ~/game && tail -50 ~/game/index.html
curl -s localhost:8080/play/ | head
```

A blank page is usually a JavaScript error in the game: ask the helper "the game is blank, can you fix it?". Paths in the game must be relative (`lib/phaser.min.js`, not `/lib/...`).

## Saves or high scores don't stick

{{#dependencies.gamedata}}
Games save through the game server into `{{dependencies.gamedata.name}}`. From a shell (below), ask it directly, then look in the log for `api` errors:

```bash
curl -s localhost:8080/play/api/status; echo
curl -s 'localhost:8080/play/api/scores?board=main'; echo
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 1h --filter-pattern api
```

- **`"saves": false`**: the box started without the table. Deploy this box.
- **`AccessDeniedException`** in the log: the task role lost the table's `read-write` policy. Deploy the table, then this box.
- **`ResourceNotFoundException`**: the table is gone. Deploy Saves & Scores, then this box.
- **Status is fine but the game forgets**: the game doesn't use `lib/saves.js`. Ask the helper "make the game remember my progress with Gamelab.save".
{{/dependencies.gamedata}}
{{^dependencies.gamedata}}
Saves & scores are off for this lab, so games remember things only until they reload. Deploy a Saves & Scores table in this environment, connected to this box, then deploy this box.
{{/dependencies.gamedata}}

## Open a shell

You need AWS credentials for this account and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

```bash
TASK=$(aws ecs list-tasks --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --service-name {{params.md_metadata.name_prefix}} --query 'taskArns[0]' --output text)
aws ecs execute-command --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --task $TASK --container lab --interactive --command "lab shell"
```

You land in `/home/player` as `player`. The agent's rules are in `/etc/gamelab/prompt.md` and its settings in `/etc/gamelab/opencode.json`; both are rewritten on every start from the image and this instance's params.

## Restart it

The games stay; a reply the helper was writing is lost.

```bash
aws ecs update-service --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --service {{params.md_metadata.name_prefix}} --force-new-deployment
```

{{#params.spot}}
On Spot, AWS can stop the box with two minutes' notice. ECS starts a new one by itself, at the same private name.
{{/params.spot}}

## Get back a game the helper broke

{{#params.home_backups}}
AWS Backup keeps a daily copy of the home directory for 35 days. In the AWS console, **AWS Backup → Protected resources**, find this box's EFS file system (`{{params.md_metadata.name_prefix}}-home`), and restore the `game` folder to a new directory, then copy the files back from a shell.
{{/params.home_backups}}
{{^params.home_backups}}
**Back up the games** is off, so there are no copies. Ask the helper to undo its last change; OpenCode keeps a history of its edits in the chat.
{{/params.home_backups}}
