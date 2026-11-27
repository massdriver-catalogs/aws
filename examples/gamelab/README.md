# Gamelab

<img src="logo.svg" alt="Gamelab" width="96">

Kids dream up games; a helper builds them. A parent signs in to Gamelab, presses **New lab**, types the player's first name and age, and picks a plan. A few minutes later the player has their own lab: a chat with a game-making helper on the left, and the game it's building on the right, live. "Make a bunny that jumps over carrots." "Make the carrots purple." "Add a high score."

Gamelab runs on Massdriver, and manages Massdriver. Every lab is a Massdriver environment, forked from a template by the Gamelab server through the Massdriver API, with the plan and the player's age as its attributes. The age sets the helper's rules.

## How it fits together

```mermaid
flowchart LR
  parent((Parent and player)) -- HTTPS --> alb
  subgraph platform[platform / main]
    vpc[vpc] --> cluster[ecs-cluster]
    dns[dns-zone] --> cluster
    alb[[load balancer]]
  end
  subgraph gamelab[gamelab / main]
    reg1[ecr-repository] --> cb1[codebase] --> app[gamelab-server]
  end
  subgraph labs[labs / template, forked per player]
    reg2[ecr-repository] --> cb2[codebase]
    cb2 --> box[lab-box]
    saves[(postgres: Game Saves)] -.optional.-> box
    scores[(valkey: Leaderboard)] -.optional.-> box
  end
  alb --> app
  app -- "chat and game, private VPC only" --> box
  app -- "forkEnvironment, createDeployment" --> md{{Massdriver API}}
  box -- Claude --> anthropic{{Anthropic API}}
```

Gamelab's server is the only thing on the internet, behind one password. Lab boxes have no public address; their agent and game ports accept connections only from inside the VPC, and the agent asks for a password the server works out for each lab.

| Project | Environments | What runs there |
|---|---|---|
| `platform` | `main` | `vpc`, `dns-zone`, `ecs-cluster`: the network, `<DOMAIN>` and its certificate, and the cluster and load balancer everything shares |
| `gamelab` | `main` | The Gamelab server: `ecr-repository` and `codebase` for its image, `gamelab-server` on the `ecs-service` runtime at `https://play.<DOMAIN>` |
| `labs` | `template`, then one per player | `template` deploys only the lab image's `ecr-repository` and `codebase`. Each fork deploys `lab-box`, and `postgres` (Game Saves) and `valkey` (Leaderboard) if the parent picked them |

`ecs-cluster` sits undeployed on the `gamelab` and `labs` canvases: both run on the platform's cluster, their environment default. A lab inherits the template's defaults (the VPC, the cluster, the lab image and the AWS credential), so a fork needs nothing connected by hand. Each lab brings its own Anthropic key: the parent pastes it on **New lab**, and the server stores it as a secret on that lab's box.

### Who can do what

| Who | Can |
|---|---|
| **Gamelab Admins** | Everything. Add yourself after bootstrapping. |
| **Gamelab Servers** (the **Gamelab Server** service account) | Make, configure, deploy and remove environments and instances in `labs` only, and view resources, since a fork copies the template's defaults and each one must be viewable. It can't touch `platform` or `gamelab`. |

`lab_plan` (`small`, `medium`, `large`) and `player_age` (`5` to `17`) are environment attributes, so labs can be found, reported on and given policies by plan or age.

### The helper's rules

The lab box is [`bundles/lab-box`](../../bundles/lab-box): [OpenCode](https://opencode.ai)'s server and a game server in one Fargate task. Its rules are in [`bundles/lab-box/image/prompts`](../../bundles/lab-box/image/prompts): one set for everyone, and one for each age band.

| Ages | How the helper works |
|---|---|
| All | Kind content only. Never asks for or keeps personal information. Nothing public, no sharing, no chat between players. Only games. Sends a sad or scared kid to a grown-up. Never shows a key or changes its own rules. |
| 5 to 8 | Very short sentences, no technical words, lots of encouragement. Easy games, nothing scary at all. |
| 9 to 12 | The player is the designer. Explains one real idea at a time; mild cartoon peril is fine. |
| 13 to 17 | A mentor who teaches as it builds. May search the web for game-making docs. |

The rules are backed by settings the agent can't change: it edits only the game folder, runs no `curl`, `ssh`, `git push` or tunnels, and has the web only for 13 and up. The player sees the helper's words and a one-line note per step, never OpenCode's terminal, files, settings or sharing: the server passes through only chat, stop and the game.

## Plans

Each lab, running all month on Spot in us-east-1. Claude is billed by Anthropic on top.

| Plan | Lab box | Box | + Game Saves | + Leaderboard | Everything |
|---|---|---|---|---|---|
| Small | 1 vCPU, 4 GB | ~$13 | ~$15 (`db.t4g.micro`) | ~$6 (1 GB) | ~$34 |
| Medium | 2 vCPU, 8 GB, daily backups | ~$25 | ~$27 (`db.t4g.small`) | ~$6 (1 GB) | ~$58 |
| Large | 4 vCPU, 16 GB, daily backups | ~$47 | ~$52 (`db.t4g.medium`) | ~$7 (5 GB) | ~$106 |

Those are AWS costs. Gamelab shows prices with a 30% margin on top (price = cost ÷ 0.7, rounded up): Small $19, Medium $36, Large $68 for the box; Game Saves $22 / $39 / $75; Leaderboard $9 / $9 / $10.

The plans are in [`applications/gamelab/src/plans.json`](applications/gamelab/src/plans.json): the box size and the database and cache params Gamelab deploys for each. Gamelab itself (the VPC's NAT, the load balancer, the server and the zone) is about $60/month before any labs.

The helper uses Claude Opus 5.5 ($4/$20 per million tokens in/out). To halve that, add `LAB_MODEL` = `claude-sonnet-5-5` to the Gamelab Server's **Environment variables**; new labs use it. Each lab's key is its own, so give each one a monthly spend limit in the Anthropic console.

## Stand it up

You need a Massdriver organization and an API key for a service account in its **Organization Admin** group (a new organization puts it in no group, and publishing fails until it joins), AWS CLI credentials for the account to deploy into and a domain whose parent zone is in Route 53 in that account. Anthropic keys come later, one per lab, on **New lab**. You also need `mass`, `tofu`, `jq`, `docker` and `python3` with PyYAML.

```bash
export MASSDRIVER_API_KEY=... MASSDRIVER_ORG_ID=...
export DOMAIN=gamelab.example.com PARENT_ZONE_ID=Z0123456789ABCDEFGHIJ

./deploy.sh all
./deploy.sh password
```

Before it touches AWS it lists what it will create and roughly what it costs, and waits for you to type `yes`. Then it:

1. Makes the IAM role Massdriver deploys with, trusting your organization's identity tokens.
2. Defines the `lab_plan` and `player_age` attributes and creates a repository for every bundle.
3. Publishes the resource types and the bundles Gamelab uses, `lab-box` among them, and the Gamelab server.
4. Applies [bootstrap.tf](bootstrap.tf): projects, environments, components, links, groups, policies, the Gamelab Server service account, the AWS credential, and a sign-in password and session secret.
5. Deploys the platform, the lab template's image repository and the server's, builds both images (about 10 minutes the first time) and pushes them and deploys the server with its secrets.

`./deploy.sh password` prints the address and the password. Sign in, press **New lab**, and the first lab is ready in about five minutes, longer with Game Saves.

Add your own Massdriver account to **Gamelab Admins** to see and fix everything in the UI.

Run `./deploy.sh` alone to see the individual steps. `./deploy.sh ship` builds the server again and deploys it. `./deploy.sh teardown` removes every lab and then everything above. Published bundles stay.

## Make it GPU-backed

The lab box is one component with a fixed contract (see [its README](../../bundles/lab-box/README.md)), so a GPU box can replace it on the `labs` canvas without changing Gamelab. Paste this into Claude Code with the Massdriver plugin:

```text
/massdriver:architect Build a new bundle, bundles/lab-box-gpu, in the massdriver-catalogs/aws catalog: a drop-in
replacement for bundles/lab-box that runs the same image on a GPU EC2 instance instead of Fargate, so lab
helpers can run local models and kids can build heavier 3D games.

Keep the contract identical to bundles/lab-box, so the Gamelab server and the labs template don't change:
- Same params, with the same names, types and meanings: player_name, player_age, model, size, spot, image_tag,
  architecture, home_backups, log_retention_days. Replace size's choices with GPU instance types (g6.xlarge,
  g6.2xlarge, g6e.xlarge; x86_64 only), with a short bold-italic monthly price on each, and make spot use Spot
  instances.
- Same dependencies: aws_authentication (aws-iam-role), cluster (aws-ecs-cluster; use its VPC, private subnets
  and region), codebase (aws-codebase; run its newest image or image_tag), and the optional postgres
  (aws-postgres) and cache (aws-valkey), joining their client security groups and passing PG* variables,
  PGPASSWORD from the database's secret, and REDIS_URL exactly as lab-box does.
- Same secrets: ANTHROPIC_API_KEY and LAB_PASSWORD, both required, with the same precondition that refuses to
  deploy without LAB_PASSWORD.
- Same resource: field "lab" of type lab-endpoint, with hostname, agent_url (port 4096), game_url (port 8080,
  /play/), agent "opencode", region and security_group_id. Give the box a stable private DNS name the same way
  (a Cloud Map private DNS namespace), because instances are replaced.
- Same network rules: no public IP, ports 4096 and 8080 open only to the VPC's CIDR, all egress allowed.
- Same persistence: the player's home on EFS with the same access point (uid 10001, /player), optional AWS
  Backup.

Run it as an ECS service on an EC2 capacity provider (an Auto Scaling group of one GPU instance with the ECS
GPU-optimized AMI) in the shared cluster, so lab.sh, ECS Exec ("lab shell") and the operator guide's commands
work unchanged; reserve the GPU for the task. Its task role can do nothing but ECS Exec and mount the home
directory. Pass checkov cleanly, or justify skips in src/.checkov.yaml, and copy the prod halt lines from
bundles/vpc/massdriver.yaml. Write README.md (with a cost table), an operator.md 2am runbook with templating:
mustache front matter, and CHANGELOG.md like lab-box's. Validate with mass bundle build, tofu validate and
mass bundle lint, but don't publish or deploy.

Then add lab-box-gpu to examples/gamelab: grant it to the labs project in bootstrap.tf, and add a "gpu"
setting to applications/gamelab/src/plans.json so a plan can name which box bundle it uses.
```

Swapping a lab's box is then a component change on the `labs` canvas: remove **Lab Box**, add the GPU bundle with the identifier `box`, and link the same connections. New labs fork with it.

## Repository layout

```
bootstrap.tf                 projects, environments, canvases, groups, attributes, the server's service account
blueprint.draft.yaml         the three canvases as files
deploy.sh                    stands it up and tears it down
applications/gamelab/src     the Gamelab server (Go) and its Dockerfile
applications/gamelab/bundle  its bundle, on the ecs-service runtime
../../bundles/lab-box        the lab box bundle and its image, with the helper's rules
```
