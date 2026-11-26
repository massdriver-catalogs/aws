# Developer Workspace

A developer's own Linux machine in the cloud: one Fargate task on a shared ECS cluster, with the home directory on EFS so work survives restarts. Developers open a shell with ECS Exec. Nothing listens on the internet, and there is no SSH.

## What's in it

- [Claude Code](https://code.claude.com) and [OpenCode](https://opencode.ai), both with the [Massdriver MCP server](https://github.com/massdriver-cloud/mcp-server) set up.
- The [`mass` CLI](https://github.com/massdriver-cloud/mass), signed in as the workspace's own Massdriver service account.
- git, git-lfs, ssh, tmux, vim, nano, ripgrep, fd, jq, curl, make, a C toolchain, Python 3 and network tools.
- [mise](https://mise.jdx.dev) for languages and anything else. **Extra tools** are installed on the first start and kept in the home directory.

## What it needs

- **An ECS cluster** with internet egress. In a sandbox it's the environment default.
- **A codebase** whose image repository holds the image built from `image/`. The workspace runs the newest image there, or the one tagged **Image tag**.
- **A Massdriver service account** that can create service accounts and add them to groups, such as one in Organization Admin. The bundle uses it to make the workspace's own service account, named after the instance; the developer never sees it.
- Optionally, the `ANTHROPIC_API_KEY` and `GH_TOKEN` secrets. Without them, the developer signs in to Claude and GitHub from the workspace, and the sign-ins are kept in the home directory.

## Build the image

```bash
docker buildx build --platform linux/arm64 --provenance=false \
  -t <registry url>:<tag> --push bundles/dev-workspace/image
```

Use `linux/amd64` when **Architecture** is x86_64. The Dockerfile pins Claude Code, OpenCode, `mass`, the MCP server and mise in its `ARG`s, and checks each download's checksum. Deploy again to pick up a new image.

## Getting in

With ECS Exec, from a laptop with AWS credentials allowed `ecs:ExecuteCommand` on the cluster and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). The operator guide has the command.

With the [Developer VPN](../developer-vpn) in the same sandbox, dev servers in the workspace on **Ports open to the VPC** open in the laptop's browser at the workspace's private IP. The VPN carries traffic; it isn't a shell.

## Cost

Running all the time on arm64 in us-east-1:

| Size | On demand | On Spot |
|---|---|---|
| 1 vCPU, 4 GB | ~$34/month | ~$10/month |
| 2 vCPU, 8 GB | ~$68/month | ~$20/month |
| 4 vCPU, 16 GB | ~$136/month | ~$41/month |

Plus EFS at ~$0.30 per GB-month (less for files not touched in 30 days), backups at ~$0.05 per GB-month, a KMS key at $1/month and a Secrets Manager secret at $0.40/month.

## Permissions

The workspace's service account joins **Massdriver groups** and nothing else. With no group it can see nothing. The task's AWS role can only open shells and mount the home directory.
