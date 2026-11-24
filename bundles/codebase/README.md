# Codebase

Where an app's images go and, when it has one, the Git repository they're built from. Runtimes connect to the codebase, not the ECR repository, so an app has one place its code comes from however much automation is behind it.

Bundles read it as `aws-codebase`. `lambda-function` and `ecs-service` attach the registry's **pull** policy to their roles, so they can run any image in it, such as the `<registry url>:<git-sha>` tags a pipeline pushes.

## How it connects

It always takes an ECR repository. The rest is optional:

- **Just a registry.** Connect only the ECR repository, turn off **Share with the project**, and link the codebase to the app on the same canvas. You push images yourself.
- **Governed repository and pipeline.** Connect the `github-repo` and `massdriver-project` bundles too, plus the Massdriver Service Account credential. The codebase then carries the repository, and sharing lets the app's own project use it.

It needs no AWS access. The Massdriver Service Account credential is only for sharing.

With **Share with the project** on, the codebase is shared with every environment whose `md-project` is the app's project, so people working there can pick it as a default without access to the onboarding project. Setting it as the default is still a step per environment, because Massdriver's Terraform provider can't set environment defaults yet:

```bash
mass environment default <project>-<environment> <codebase resource ID>
```

## The project field

The resource type has a `project` field, commented out. Bundles that consume a codebase already run in the project it was made for, so carrying the project too would add a second source of truth that can disagree with where the bundle actually is. Uncomment it in the `aws-codebase` resource type and in this bundle's `src/main.tf` if bundles need the project's identifier or environment list.

## Decommissioning

Decommissioning deletes the codebase and stops sharing it. Environments that have it as their default lose that default; the repository and ECR repository are untouched.
