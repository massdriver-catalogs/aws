# Gamelab Server

Gamelab's web app, in Go. A parent signs in with one password, makes a lab for a player (first name, age, plan, extras), and watches it build. The player then chats with the lab's helper on the left and plays the game it builds on the right.

Runs on the catalog's `ecs-service` runtime; this bundle adds the app's settings and secrets.

## What it does in Massdriver

As the **Gamelab Server** service account, which may change only the `labs` project:

1. `forkEnvironment` from `labs-template`, copying its defaults (network, cluster, lab image, AWS credential) and its secrets (the Anthropic key), with `lab_plan` and `player_age` as environment attributes.
2. `setInstanceSecret` on the new lab's box: its agent password, worked out from `SESSION_SECRET`, so nothing is stored.
3. `createDeployment` for Game Saves and Leaderboard if picked, waiting for each, then for the box with the plan's size and the player's name and age.
4. **Remove** runs `decommissionEnvironment`; once everything is down, the server deletes the environment.

## What it proxies

Only these, over the VPC, to the box in the lab's `lab-box` resource:

| Gamelab route | Lab box |
|---|---|
| `GET /labs/<id>/chat` | the agent's messages and status, cut down to its words and a one-line note per step |
| `POST /labs/<id>/chat` | a new message to the agent |
| `POST /labs/<id>/stop` | stop the agent's turn |
| `GET /labs/<id>/play/<token>/...` | the game server, read-only |

Nothing else of the agent's API is reachable: not its terminal, files, settings or sharing.

## Needs

- The environment's ECS cluster with a DNS zone, as an environment default.
- The `gamelab` project's codebase, holding the image built from `src/`.
- Secrets `GAMELAB_PASSWORD`, `SESSION_SECRET`, `MASSDRIVER_API_KEY`, and `MASSDRIVER_ORGANIZATION_ID` in **Environment variables**. `deploy.sh` sets all four.

## Run it on a laptop

With no Massdriver settings it serves one lab: a lab box running on the same machine.

```bash
docker build -t gamelab-lab-box bundles/lab-box/image
docker run -d -p 4096:4096 -p 8080:8080 -e LAB_PASSWORD=pw -e PLAYER_NAME=Sam -e PLAYER_AGE=7 \
  -e ANTHROPIC_API_KEY=sk-ant-... gamelab-lab-box
cd examples/gamelab/applications/gamelab/src
GAMELAB_PASSWORD=letmein1 SESSION_SECRET=$(openssl rand -hex 16) LOCAL_LAB_PASSWORD=pw PORT=3000 go run .
```

Open http://localhost:3000.
