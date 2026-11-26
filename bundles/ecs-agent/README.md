# ECS Agent

A Claude agent that works on one goal, around the clock, in one Fargate task on a shared ECS cluster. It has its own Massdriver service account, so everything it does shows in the audit log under its name, and it can only do what its groups allow.

## How it works

The task runs [Claude Code](https://code.claude.com) in headless mode in a loop. Each run reads the **Goal**, reads the notes it left last time, works until there's nothing more to do, rewrites its notes, and stops. The next run starts **Minutes between runs** later. A run also stops when it has spent **Most spent per run**.

The agent's tools:

- The [Massdriver MCP server](https://github.com/massdriver-cloud/mcp-server) and the [`mass` CLI](https://github.com/massdriver-cloud/mass), both signed in as the agent's service account.
- curl, jq, dig, nc, ping, traceroute, ss, ip, tcpdump, openssl and git.
- [mise](https://mise.jdx.dev), for anything else. **Extra tools** are installed each time the task starts, and the agent can install more itself.
- **More MCP servers**: other tools, local or remote.

The agent has no AWS access. It works through Massdriver.

## What it needs

- **An ECS cluster** with internet egress, to reach Claude and Massdriver.
- **A Massdriver service account** that can create service accounts, add them to groups and create event destinations, such as one in Organization Admin. The bundle uses it to make the agent's own service account; the agent never sees it.
- **The `ANTHROPIC_API_KEY` secret**, set on the instance.
- **The agent image**, built from `image/` and pushed somewhere the cluster can pull from.
- **A codebase** (optional) lets the task pull the image from its ECR repository.

## Build the image

```bash
docker buildx build --platform linux/arm64 \
  -t <registry>/ecs-agent:0.1.0 --push bundles/ecs-agent/image
```

Use `linux/amd64` when **Architecture** is x86_64. The Dockerfile pins the versions of Claude Code, `mass`, the MCP server and mise in its `ARG`s; change them there and push a new tag.

## Permissions

The agent's service account joins **Groups** and nothing else. Give it a group made for it, with only the actions its goal needs. `instance:propose` without `instance:deploy` lets it suggest a deploy that a person approves.

## Sending its actions to a webhook

With **Send actions** on, Massdriver sends every event whose actor is the agent's service account to **Webhook URL**: every change it makes, and every deploy it starts. Each request is a CloudEvent, signed with [Standard Webhooks](https://www.standardwebhooks.com) headers. The operator guide shows where to find the signing secret.

## More MCP servers

A local server runs a command in the container, so its runtime must be there: add `node@22` to **Extra tools** for an `npx` server, or `uv` for a `uvx` one. A remote server is a URL.

Keep credentials out of the form. Put them in the `MCP_ENV` secret as JSON, like `{"GRAFANA_TOKEN": "glsa_..."}`, and write `${GRAFANA_TOKEN}` in an argument, environment variable or header.
