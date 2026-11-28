# Gamelab

<img src="logo.svg" alt="Gamelab" width="96">

Kids dream up games; a helper builds them. A parent signs in to Gamelab, presses **New lab**, types the player's first name and age, and picks a plan. A few minutes later the player has their own lab: a chat with a game-making helper on the left, and the game it's building on the right, live. "Make a bunny that jumps over carrots." "Make the carrots purple." "Add a high score."

Gamelab runs on Massdriver, and manages Massdriver. Every lab is a Massdriver environment, forked from a template by the Gamelab server through the Massdriver API, with the plan and the player's age as its attributes. The age sets the helper's rules.

## How it fits together

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture.dark.svg">
  <img src="diagrams/architecture.svg" alt="A parent or player reaches the Gamelab server over HTTPS through the load balancer. The server, in the platform VPC's private subnets, chats with the helper (OpenCode, port 4096) on each player's lab box with the lab's password, serves the game server's files and saves and scores calls, sets each box's ECS task count to sleep and wake it, and calls the Massdriver API as the Gamelab Server service account. On the box, the helper and the game server share a home folder on EFS. The helper calls the Anthropic API through the VPC's NAT with the lab's own key. The game server writes to the lab's optional DynamoDB table with the box's task role. ECR holds the server image and the lab image.">
</picture>

The Gamelab server is the only thing on the internet. It sits behind the platform's load balancer, and everyone signs in with one password. Each lab box has no public address. Its two ports accept connections only from inside the VPC, and the server finds each box by a private name (`box.<lab>-box.internal`, from Cloud Map) that follows the task when it restarts. The box calls Claude with the Anthropic key the parent gave for that lab, so each lab's Claude bill is its own.

The game runs in a sandboxed frame on the lab page. Its files load through `/labs/<lab>/play/<token>/`, where the token is signed by the server, because a sandboxed frame sends no cookie. The server passes reads through to the game, plus `POST` and `PUT` to `api/` for saves and scores, up to 64 KB each, and strips cookies on the way.

## How Massdriver sees it

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/projects.dark.svg">
  <img src="diagrams/projects.svg" alt="The AWS credential, open to every environment, is the default of platform main, gamelab main and the labs template. platform main (Network, DNS Zone, ECS Cluster) provides network, zone and cluster defaults to gamelab main (Image Repository, Codebase, Lab Power, Gamelab Server), and network and cluster defaults to the labs template (Lab Image Repository, Lab Codebase), which also makes its lab codebase its own default. forkEnvironment copies the template's defaults into each lab, such as labs-maya (Lab Box, Saves &amp; Scores) and labs-sam (Lab Box).">
</picture>

Three projects, each with its own canvas. `platform` holds what everything shares. `gamelab` holds the server. `labs` holds one `template` environment and one forked environment per player. Each box above lists what's deployed in that environment. A fork copies the template's environment defaults (the VPC, the cluster, the lab codebase and the AWS credential), so a new lab needs nothing connected by hand. It doesn't copy secrets.

The `labs` canvas is the same for every lab. What changes is which parts are deployed:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/lab-canvas.dark.svg">
  <img src="diagrams/lab-canvas.svg" alt="On a lab's canvas, the Lab Image Repository (ecr-repository) connects to the Lab Codebase (codebase) through repository, and the codebase, the ECS Cluster (ecs-cluster) and Saves &amp; Scores (dynamodb-table) connect to the Lab Box (lab-box) through codebase, cluster and table.">
</picture>

| Component | In `template` | In each lab |
|---|---|---|
| Lab Image Repository, Lab Codebase | Deployed. The lab image is built here once. | Not deployed. The template's codebase is the default. |
| ECS Cluster | Not deployed. The platform's cluster is the default. | Same. |
| Lab Box | Not deployed. | Deployed. |
| Saves & Scores | Not deployed. | Deployed only if the parent picked it. |

The `gamelab` canvas works the same way: its ECS Cluster sits undeployed, and the server runs on the platform's cluster. Lab Power, an `ecs-scaling-policy`, is linked to the server and gives its task role the right to change the task count of `labs-*` services on that cluster, and nothing else.

| Project | Environments | What runs there |
|---|---|---|
| `platform` | `main` | `vpc`, `dns-zone`, `ecs-cluster`: the network, `<DOMAIN>` and its certificate, and the cluster and load balancer everything shares |
| `gamelab` | `main` | The Gamelab server: `ecr-repository` and `codebase` for its image, `ecs-scaling-policy` (Lab Power), and `gamelab-server` on the `ecs-service` runtime at `https://play.<DOMAIN>` |
| `labs` | `template`, then one per player | `template` deploys only the lab image's `ecr-repository` and `codebase`. Each fork deploys `lab-box`, and `dynamodb-table` (Saves & Scores) if the parent picked it |

`lab_plan` (`small`, `medium`, `large`) and `player_age` (`5` to `17`) are environment attributes, so labs can be found, reported on and given policies by plan or age.

## What happens when a parent makes a lab

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/new-lab.dark.svg">
  <img src="diagrams/new-lab.svg" alt="Making a lab: the parent submits the first name, age, lesson, plan, extras and Anthropic key. The server checks them, forks labs-template into labs-maya with lab_plan and player_age, and shows the lab page as getting ready. In the background, for up to 90 minutes, it sets the LAB_PASSWORD and ANTHROPIC_API_KEY secrets on labs-maya-box, deploys labs-maya-gamedata when saves and scores were picked and waits for it, then deploys labs-maya-box with the name, age, lesson, model and the plan's size, waits for it, and tells the parent the lab is ready to play.">
</picture>

The server checks the form, forks the template, and shows the lab page right away. Then it sets the box's two secrets and deploys the table first, because the box connects to it when it starts. The lab's password is never stored: the server works it out again from its session secret whenever it talks to the box. The Anthropic key goes straight to Massdriver as a secret, and the server keeps no copy. Massdriver holds all the state, so if a setup stops, **Try again** runs it again and every step skips what's already done.

The lesson is a param of the lab's box, so Massdriver keeps it with everything else; it isn't an attribute, since attributes take a fixed set of values. Changing it on the lab page deploys the box with the new one. The box restarts to pick it up, and a sleeping box stays asleep and has it when it wakes.

Removing a lab decommissions its environment, or deletes it right away if nothing is deployed. A sweep every minute deletes environments whose box finished decommissioning.

## What happens when a player asks for something

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/chat.dark.svg">
  <img src="diagrams/chat.svg" alt="A chat turn: the player taps Talk or types, and the lab page posts the message. The server checks the player is signed in, on the same site, the lab is ready and the message is under 2,000 characters, sends it to OpenCode with the lab's password, and accepts it. In parallel, OpenCode sends the message with the age rules to Claude and edits files in ~/game, while the page polls the server every 1.5 seconds while busy and every 4 seconds when idle for the helper's words and steps. When busy turns to idle, the page reloads the game from the game server through the server, without cookies, and index.html is never cached.">
</picture>

**Talk** uses the browser's speech recognition. When the player stops talking, the words send on their own. The player sees only the helper's words and a short line per step, like "Changed index.html", never code, files, settings or a terminal. When the helper finishes, the game reloads with the change. **Full screen** takes the whole Play panel full screen, so **Reload** stays in reach on an iPad. Every game loads `lib/screen.js`, which fits it to the screen in either direction and adds big touch buttons for the keys it uses.

## Who can do what

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/access.dark.svg">
  <img src="diagrams/access.svg" alt="Gamelab Admins can do everything in the platform, gamelab and labs projects. The Gamelab Server service account can make, set up, deploy and remove environments in labs, and only view resources in platform and gamelab. A lab box's AWS role can mount its own home folder, open an ECS Exec shell for admins, and read and write its own Saves &amp; Scores table. The server's AWS role can change only the task count of the labs ECS services. The helper on a box can edit only ~/game.">
</picture>

| Who | Can |
|---|---|
| **Gamelab Admins** | Everything, everywhere. Add yourself after bootstrapping. |
| **Gamelab Servers** (the **Gamelab Server** service account) | Where `md-project` is `labs`: `project:view`, `environment:create`, `environment:update`, `environment:configure`, `environment:deploy`, `environment:decommission`, `environment:delete`, `instance:configure`, `instance:plan`, `instance:deploy`, `instance:decommission`. Everywhere: `resource:view` and nothing else. |
| **A lab box** | In Massdriver, nothing: it has no Massdriver credentials. In AWS, its task role can mount its own home folder through its own access point, open an ECS Exec shell, and read and write its own Saves & Scores table. Only the game server, running as its own user, gets those credentials; the helper can't read them. |
| **The server's AWS role** | `ecs:DescribeServices` and `ecs:UpdateService` on `labs-*` services on the platform cluster, from Lab Power. An update that also changes a task definition, capacity provider, subnets, public IP or ECS Exec is denied, so it can't make a box run as anything else. |
| **The helper** | Edit files in the game folder, and run commands in the box as the player. |

The server needs `resource:view` everywhere because a fork copies the template's defaults, and those point at resources in `platform` and at the AWS credential, which must be viewable to copy. It reads each box's `lab` resource to find its addresses. It can't deploy, configure or remove anything in `platform` or `gamelab`, including itself.

Bundles are scoped the same way. New bundles aren't granted to every project. `lab-box` is granted only to `labs`, `gamelab-server` and `ecs-scaling-policy` only to `gamelab`, and the shared bundles (`vpc`, `dns-zone`, `ecs-cluster`, `ecr-repository`, `codebase`, `ecs-service`, `dynamodb-table`) to all three. The platform's network, zone and cluster are shared with `gamelab` and `labs` only, and the lab codebase with `labs` only.

### Secrets

Secrets are never params, so they never show in a form, a deployment's params or the API's params history.

- The server's `GAMELAB_PASSWORD`, `SESSION_SECRET` and `MASSDRIVER_API_KEY` come from `bootstrap.tf`. `bootstrap.sh` sets them with `setInstanceSecret`, passing each value through the environment and stdin, so it never shows in a process list.
- A box's `LAB_PASSWORD` and `ANTHROPIC_API_KEY` are set by the server with `setInstanceSecret`. The bundle writes them to Secrets Manager under the box's own KMS key, and ECS reads them when the task starts. The box refuses to deploy, and the agent refuses to start, without `LAB_PASSWORD`.
- A fork copies no secrets, so one lab never gets another's key.

### The helper's rules

The lab box is [`bundles/lab-box`](../../bundles/lab-box): [OpenCode](https://opencode.ai)'s server and a game server in one Fargate task. Its rules are in [`bundles/lab-box/image/prompts`](../../bundles/lab-box/image/prompts): one set for everyone, and one for each age band.

| Ages | How the helper works |
|---|---|
| All | Kind content only. Never asks for or keeps personal information. Nothing public, no sharing, no chat between players. Only games. Sends a sad or scared kid to a grown-up. Never shows a key or changes its own rules. |
| 5 to 8 | Very short sentences, no technical words, lots of encouragement. Easy games, nothing scary at all. |
| 9 to 12 | The player is the designer. Explains one real idea at a time; mild cartoon peril is fine. |
| 13 to 17 | A mentor who teaches as it builds. May search the web for game-making docs. |
| With a lesson | Builds the lesson into every new game, at the player's level: collect the right answer, solve to open the door. Says in one sentence what a game practices, cheers right answers and gently shows the right one after a miss. Doesn't rewrite a game the player already has. |

A lesson is a topic a parent types, like "counting to 20". It comes after every other rule in the prompt, quoted, as a topic only: letters, numbers and simple punctuation, up to 200 characters, checked by the server, the bundle and `lab.sh`. If it isn't something to teach a kid, the helper ignores it and makes regular games. A lab without a lesson has no lesson in its prompt at all.

The rules are backed by settings the agent can't change. When the box starts, `lab.sh` writes the prompt and OpenCode's settings to `/etc/gamelab`, outside the player's home, and runs the agent as the player. The settings let it edit only the game folder, never its own settings. Its shell can't run `curl`, `wget`, `ssh`, `scp`, `sudo`, `git push` or tunnels. Web search and fetch are on only for players 13 and up. Sharing is off, and only Anthropic models are allowed. The box itself can still reach the internet, because Claude and npm are there.

## How changes get deployed

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/bootstrap.dark.svg">
  <img src="diagrams/bootstrap.svg" alt="bootstrap.sh publish publishes the resource types, the bundles and the server's bundle. bootstrap.sh projects applies bootstrap.tf: projects, canvases, groups, policies, the service account and the AWS credential. bootstrap.sh provision deploys the platform, then the lab image, then the server. The server then forks labs on the template's versions.">
</picture>

`bootstrap.sh` publishes every bundle first, then `bootstrap.tf` builds the projects and permissions around them, then `provision` deploys the platform, the lab template's image repository and codebase, and the server. With `DEV=1`, it publishes development releases, records the exact version of each, and pins every instance to that version, including the template's Lab Box and Saves & Scores. Forks take the template's versions, so every lab runs the same releases. `./bootstrap.sh ship` rebuilds only the server's image and deploys it.

Every bundle runs Checkov on each deploy. In an environment named `prod` or `production`, a failed check stops the deploy. Anywhere else, it reports and goes on. Lab Box skips one check, Secrets Manager rotation, because its secrets are an Anthropic key and a password that only a deploy changes.

## Saves and high scores

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/scores.dark.svg">
  <img src="diagrams/scores.svg" alt="Saving a score: the game, in a sandboxed frame, calls Gamelab.addScore(&quot;Maya&quot;, 1200) from lib/saves.js, which posts to the server's api/scores path for the lab. The server checks the signed token, a body of 64 KB at most and POST only under api/, and forwards it to the game server on the box. The game server accepts a first name of letters only and a whole-number score, at most 120 writes a minute, puts the item in the Saves &amp; Scores table and trims the board to the top ten, and returns rank 1, the best score and the top ten. The game shows New high score!">
</picture>

The game runs in a sandboxed frame with no lasting browser storage, so it remembers things through the box. Games load `lib/saves.js` and call `Gamelab.save(slot, data)`, `Gamelab.load(slot)`, `Gamelab.addScore(name, score)` and `Gamelab.scores()`. The helper is told to use these, never `localStorage`. The game server on the box keeps them in the lab's own DynamoDB table, with the box's task role, which can touch only that table. A save is up to 12 KB in one of 20 slots; a board keeps its top ten, and a name on it is letters only, up to 12, so only a first name or nickname fits.

When a lab has no table, the same calls keep everything in memory until the game reloads, so a game works the same in every lab. The lab box's README lists every call.

## Sleep and wake

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/sleep-wake.dark.svg">
  <img src="diagrams/sleep-wake.svg" alt="Sleep and wake: every minute the server finds boxes unused for 30 minutes whose helper isn't working on a reply, and sets their ECS service's desired count to 0; ECS stops the task and the home folder stays on EFS. When the player opens the lab, the server sees desired count 0, sets it to 1, and the page shows Waking up your lab. Every 4 seconds the page asks again while the server checks the service is running and the box's /play/healthz answers, then the page shows the chat and the game as they were.">
</picture>

A lab box nobody has used for 30 minutes goes to sleep. Using means sending a chat message, the game asking the server for anything, or a tap or key press in the game, which `lib/screen.js` reports at most once a minute. A lab page left open doesn't count, and a box never sleeps while its helper is working on a reply. Opening the lab page or the game wakes it; waking took about a minute in testing (51 seconds from opening the lab page to the game). While it sleeps, the home page says the lab is napping, and an open lab page shows a **Wake it up** button.

The server scales the box's ECS service directly instead of deploying through Massdriver, which would take minutes. It keeps the last use of each lab in memory; after a restart it counts every running box as used just then. Whether a box is asleep comes from ECS, so the pages are right after a restart. The box's service ignores its desired count on deploys, so a Massdriver deploy leaves a sleeping box asleep, with the new version ready for when it wakes.

`LAB_IDLE_MINUTES` in the Gamelab Server's **Environment variables** changes the 30 minutes.

## Plans

Each lab on Spot in us-east-1. Claude is billed by Anthropic on top.

| Plan | Lab box | All month | Used 2 hours a day | + Saves & Scores |
|---|---|---|---|---|
| Small | 1 vCPU, 4 GB | ~$13 | ~$3 | ~$0.30 |
| Medium | 2 vCPU, 8 GB, daily backups | ~$25 | ~$4 | ~$0.30 |
| Large | 4 vCPU, 16 GB, daily backups | ~$47 | ~$7 | ~$0.30 |

A sleeping box costs nothing for compute. What's left runs all month: about $2 to $3 for the box's KMS key, secret, private DNS zone, logs and home folder, and its backups. Saves & Scores is a DynamoDB table on demand, cents a month for a lab's saves, plus its throttling alarm.

Those are AWS costs. Gamelab shows prices with a 30% margin on top (price = cost ÷ 0.7, rounded up), for a box running all month: Small $19, Medium $36, Large $68; Saves & Scores $1.

The plans are in [`applications/gamelab/src/plans.json`](applications/gamelab/src/plans.json): the box size and the table params Gamelab deploys for each. Gamelab itself (the VPC's NAT, the load balancer, the server and the zone) is about $60/month before any labs.

The helper uses Claude Opus 5.5 ($4/$20 per million tokens in/out). To halve that, add `LAB_MODEL` = `claude-sonnet-5-5` to the Gamelab Server's **Environment variables**; new labs use it. Each lab's key is its own, so give each one a monthly spend limit in the Anthropic console.

## Stand it up

You need a Massdriver organization and an API key for a service account in its **Organization Admin** group (a new organization puts it in no group, and publishing fails until it joins), AWS CLI credentials for the account to deploy into and a domain whose parent zone is in Route 53 in that account. Anthropic keys come later, one per lab, on **New lab**. You also need `mass`, `tofu`, `jq`, `docker` and `python3` with PyYAML.

```bash
export MASSDRIVER_API_KEY=... MASSDRIVER_ORG_ID=...
export DOMAIN=gamelab.example.com PARENT_ZONE_ID=Z0123456789ABCDEFGHIJ

./bootstrap.sh all
./bootstrap.sh password
```

Before it touches AWS it lists what it will create and roughly what it costs, and waits for you to type `yes`. Then it:

1. Makes the IAM role Massdriver deploys with, trusting your organization's identity tokens.
2. Defines the `lab_plan` and `player_age` attributes and creates a repository for every bundle.
3. Publishes the resource types and the bundles Gamelab uses, `lab-box` among them, and the Gamelab server.
4. Applies [bootstrap.tf](bootstrap.tf): projects, environments, components, links, groups, policies, the Gamelab Server service account, the AWS credential, and a sign-in password and session secret.
5. Deploys the platform, the lab template's image repository and the server's, builds both images (about 10 minutes the first time) and pushes them and deploys the server with its secrets.

`./bootstrap.sh password` prints the address and the password. Sign in, press **New lab**, and the first lab is ready in about five minutes.

Add your own Massdriver account to **Gamelab Admins** to see and fix everything in the UI.

Run `./bootstrap.sh` alone to see the individual steps. `./bootstrap.sh ship` builds the server again and deploys it. `./bootstrap.sh teardown` removes every lab and then everything above. Published bundles stay.

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
  and region), codebase (aws-codebase; run its newest image or image_tag), and the optional gamedata
  (aws-dynamodb-table), attaching its read-write policy to the task role and passing GAMELAB_TABLE and
  GAMELAB_TABLE_REGION exactly as lab-box does.
- Same secrets: ANTHROPIC_API_KEY and LAB_PASSWORD, both required, with the same precondition that refuses to
  deploy without LAB_PASSWORD.
- Same resource: field "lab" of type lab-endpoint, with hostname, agent_url (port 4096), game_url (port 8080,
  /play/), agent "opencode", region, security_group_id, cluster_arn and service_name. Give the box a stable private DNS name the same way
  (a Cloud Map private DNS namespace), because instances are replaced.
- Same network rules: no public IP, ports 4096 and 8080 open only to the VPC's CIDR, all egress allowed.
- Same persistence: the player's home on EFS with the same access point (uid 10001, /player), optional AWS
  Backup.

Run it as an ECS service on an EC2 capacity provider (an Auto Scaling group of one GPU instance with the ECS
GPU-optimized AMI) in the shared cluster, so lab.sh, ECS Exec ("lab shell") and the operator guide's commands
work unchanged; reserve the GPU for the task, and ignore desired_count changes so Gamelab can put it to sleep.
Its task role can do nothing but ECS Exec, mount the home directory and use the gamedata table. Pass checkov cleanly, or justify skips in src/.checkov.yaml, and copy the prod halt lines from
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
bootstrap.sh                 stands it up and tears it down
applications/gamelab/src     the Gamelab server (Go) and its Dockerfile
applications/gamelab/bundle  its bundle, on the ecs-service runtime
../../bundles/lab-box        the lab box bundle and its image, with the helper's rules
```
