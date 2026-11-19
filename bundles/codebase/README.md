# Codebase

Where an app's code lives and where its images go, as one resource: its GitHub repository and its ECR repository.

## Why one resource

Every runtime in the app's project needs the registry, in every environment. Links across projects would be set per instance, and a new environment would start without them. One resource, set once as each environment's default, reaches every bundle there.

Bundles read it as `aws-codebase`. `lambda-function` and `ecs-service` attach the registry's **pull** policy to their roles and run `registry.url:<git-sha>`.

## How it connects

It takes the other onboarding bundles: the repository, the ECR repository and the Massdriver project. It needs no cloud access of its own.

With **Share with the project** on, the codebase is shared with every environment whose `md-project` is the app's project, so people working there can pick it as a default without access to the onboarding project. Setting it as the default is still a step per environment, because Massdriver's Terraform provider can't set environment defaults yet:

```bash
mass environment default <project>-<environment> <codebase resource ID>
```

## The project field

The resource type has a `project` field, commented out. Bundles that consume a codebase already run in the project it was made for, so carrying the project too would add a second source of truth that can disagree with where the bundle actually is. Uncomment it in the `aws-codebase` resource type and in this bundle's `src/main.tf` if bundles need the project's identifier or environment list.

## Decommissioning

Decommissioning deletes the codebase and stops sharing it. Environments that have it as their default lose that default; the repository and ECR repository are untouched.
