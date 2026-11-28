# Lab Box

A private box where a coding agent builds browser games with a kid. One Fargate task on a shared ECS cluster runs two servers, reachable only inside the VPC:

- **The agent**, [OpenCode](https://opencode.ai)'s HTTP API (`opencode serve`) on port 4096, behind a password.
- **The game**, a small web server on port 8080 that serves `~/game` at `/play/` with nothing cached, so a reload shows the agent's latest change. Under `/play/api/` it also keeps the game's saves and high scores in the lab's DynamoDB table, when one is connected.

Something inside the VPC, such as the Gamelab server, proxies both to a browser. The box has no public address and no load balancer.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/task.dark.svg">
  <img src="diagrams/task.svg" alt="A proxy inside the VPC, such as the Gamelab server, reaches the lab box's Fargate task in private subnets. lab.sh runs as root, writes the prompt and settings to /etc/gamelab, then starts opencode serve on port 4096 as the player with LAB_PASSWORD, and game-server.mjs on port 8080 as gameserver (uid 10002), with /play/ read only and /play/api/ for saves. The proxy uses basic auth to the helper, and GET plus POST and PUT under /play/api/ to the game server. The helper edits ~/game and the game server reads it, on the EFS home /home/player (uid 10001). The helper calls the Anthropic API. The game server reads and writes the optional gamedata DynamoDB table with the task role, on that table only.">
</picture>

The proxy finds the box by name. The box registers a private name in Cloud Map, `box.<name prefix>.internal`, which follows the task across restarts and is published as the `lab` resource's `hostname`. Only one task runs at a time, so two never write to the same home folder.

## What it needs and makes

The contract a replacement must keep, so a GPU box or another agent can take its place on the same canvas:

| | Name | Type | |
|---|---|---|---|
| Needs | `cluster` | `aws-ecs-cluster` | Its VPC and private subnets; ECS runs the task there |
| Needs | `codebase` | `aws-codebase` | The image repository holding `image/` |
| Needs, optional | `gamedata` | `aws-dynamodb-table` | Saves & scores; the task role gets its `read-write` policy, and the game server answers `/play/api/` from it |
| Params | `player_name`, `player_age`, `lesson`, `model`, `size`, `spot`, `image_tag`, `architecture`, `home_backups`, `log_retention_days` | | |
| Secrets | `ANTHROPIC_API_KEY`, `LAB_PASSWORD` | | |
| Makes | `lab` | `lab-endpoint` | `agent_url`, `game_url`, `hostname`, `agent`, `region`, `cluster_arn`, `service_name` |

`agent_url` speaks the OpenCode server API with basic auth (`opencode` / `LAB_PASSWORD`); `game_url` serves the game read-only, plus the saves API below.

## Saves and scores

Games load `lib/saves.js` and call `Gamelab.save`, `Gamelab.load`, `Gamelab.addScore` and `Gamelab.scores`. The helper sends them to the game server, which keeps them in the `gamedata` table. Without a table, or if a call fails, the helper keeps them in memory until the game reloads, so a game works the same either way.

| Call | Does |
|---|---|
| `GET api/status` | `{ "saves": true }` when a table is connected |
| `PUT` or `POST api/save` `{ slot, data }` | Saves any JSON value up to 12 KB in a slot (letters, digits, `-` and `_`, up to 32); at most 20 slots |
| `GET api/load?slot=` | `{ slot, data, savedAt }`, or 404 |
| `GET api/saves` | Every slot and when it was saved |
| `GET api/scores?board=` | The top ten on a board (default `main`), best first |
| `POST api/scores` `{ name, score, board }` | Adds a score; gives `{ rank, best, scores }`. Names are letters only, up to 12, so only a first name or nickname fits. Only the top ten are kept |
| `GET api/ping` | Nothing; the game calls it when the player taps or presses a key, so the lab knows someone is playing |

Bodies are capped at 16 KB, and writes at 120 a minute. Without a table, everything but `status` and `ping` answers 503. Calls are cross-origin from the game's sandboxed frame, so they answer with `Access-Control-Allow-Origin: *`; the signed address the proxy puts in front is what keeps them private.

In the table, a save is `pk = save`, `sk = <slot>`, and a score is `pk = score`, `sk = <board>#<score>#<time>`.

## Sleeping

Whatever proxies to the box may set the service's desired count to 0 when nobody has used the lab for a while, and back to 1 when someone opens it; Gamelab does this after 30 minutes. The home folder and the table are kept, so nothing is lost; waking takes about a minute. The service ignores its desired count on deploys, so a deploy leaves a sleeping box asleep, with the new task definition ready for when it wakes. `cluster_arn` and `service_name` in the `lab` resource say which service to scale.

## The agent's rules

The image holds the rules in `image/prompts/`: `base.md` for every player, and one file per age band (5 to 8, 9 to 12, 13 to 17) for how it talks and what a game may contain. At start, `lab.sh` puts them together with the player's first name and age and whether Saves & scores are on, then `lesson.md` with the lesson quoted in it when the box has one, and writes the agent's settings outside the player's home, where the agent can't edit them.

What the settings enforce, beyond the prompt:

- One agent, `gamelab`, the default. Sharing is off. Only Anthropic models.
- The agent may edit only inside the game folder, never its own settings.
- No `curl`, `wget`, `ssh`, `git push`, `sudo` or tunnels from its shell. Web search and fetch only for players 13 and up.
- Nothing waits for approval, since the person chatting is a kid.

The box itself has no Massdriver credentials. Its AWS role can mount the home directory, open an admin shell, and read and write the lab's own table. Only the game server, which runs as its own user, gets the role's credentials; the agent, running as the player, can't read them.

## What's in the image

Debian, [OpenCode](https://opencode.ai), Node.js, `mass`, git, [mise](https://mise.jdx.dev), and game libraries the agent loads with no internet: Phaser, KAPLAY and three.js in `/opt/gamelab/lib`, at `lib/` in the game folder. The Dockerfile pins each version and checks each download's checksum.

```bash
docker buildx build --platform linux/arm64 --provenance=false \
  -t <registry url>:<tag> --push bundles/lab-box/image
```

Use `linux/amd64` when **Architecture** is x86_64.

## Cost

Running all the time on arm64 in us-east-1:

| Size | On demand | On Spot |
|---|---|---|
| 1 vCPU, 4 GB | ~$34/month | ~$10/month |
| 2 vCPU, 8 GB | ~$68/month | ~$20/month |
| 4 vCPU, 16 GB | ~$136/month | ~$41/month |

A sleeping box costs nothing for compute. A box used about two hours a day costs a twelfth of the above: ~$1, ~$2 and ~$3 a month on Spot.

Plus about $3/month for its KMS key, secret, private DNS zone, logs and a small EFS home directory, awake or asleep, and backups at ~$0.05 per GB-month. A Saves & scores table on demand is cents a month. Claude is billed by Anthropic per token on top.
