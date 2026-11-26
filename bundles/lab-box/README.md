# Lab Box

A private box where a coding agent builds browser games with a kid. One Fargate task on a shared ECS cluster runs two servers, reachable only inside the VPC:

- **The agent**, [OpenCode](https://opencode.ai)'s HTTP API (`opencode serve`) on port 4096, behind a password.
- **The game**, a small web server on port 8080 that serves `~/game` at `/play/` with nothing cached, so a reload shows the agent's latest change.

Something inside the VPC, such as the Gamelab server, proxies both to a browser. The box has no public address and no load balancer.

## What it needs and makes

The contract a replacement must keep, so a GPU box or another agent can take its place on the same canvas:

| | Name | Type | |
|---|---|---|---|
| Needs | `cluster` | `aws-ecs-cluster` | Its VPC and private subnets; ECS runs the task there |
| Needs | `codebase` | `aws-codebase` | The image repository holding `image/` |
| Needs, optional | `postgres` | `aws-postgres` | Game saves; the agent gets `PG*` variables and `psql` |
| Needs, optional | `cache` | `aws-valkey` | Leaderboards; the agent gets `REDIS_URL` and `valkey-cli` |
| Params | `player_name`, `player_age`, `model`, `size`, `spot`, `image_tag`, `architecture`, `home_backups`, `log_retention_days` | | |
| Secrets | `ANTHROPIC_API_KEY`, `LAB_PASSWORD` | | |
| Makes | `lab` | `lab-box` | `agent_url`, `game_url`, `hostname`, `agent`, `region` |

`agent_url` speaks the OpenCode server API with basic auth (`opencode` / `LAB_PASSWORD`); `game_url` serves the game read-only.

## The agent's rules

The image holds the rules in `image/prompts/`: `base.md` for every player, and one file per age band (5 to 8, 9 to 12, 13 to 17) for how it talks and what a game may contain. At start, `lab.sh` puts them together with the player's first name and age and which databases are connected, and writes the agent's settings outside the player's home, where the agent can't edit them.

What the settings enforce, beyond the prompt:

- One agent, `gamelab`, the default. Sharing is off. Only Anthropic models.
- The agent may edit only inside the game folder, never its own settings.
- No `curl`, `wget`, `ssh`, `git push`, `sudo` or tunnels from its shell. Web search and fetch only for players 13 and up.
- Nothing waits for approval, since the person chatting is a kid.

The box itself has no Massdriver credentials, and its AWS role can do nothing but mount the home directory and open an admin shell.

## What's in the image

Debian, [OpenCode](https://opencode.ai), Node.js, `mass`, git, [mise](https://mise.jdx.dev), `psql`, `valkey-cli`, and game libraries the agent loads with no internet: Phaser, KAPLAY and three.js in `/opt/gamelab/lib`, at `lib/` in the game folder. The Dockerfile pins each version and checks each download's checksum.

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

Plus about $3/month for its KMS key, secret, private DNS zone, logs and a small EFS home directory, and backups at ~$0.05 per GB-month. Claude is billed by Anthropic per token on top.
