# Massdriver Project

The Massdriver project an app lives in. In the onboarding project, every environment deploys one of these, so adding an environment there adds an app.

## What it creates

- **The project**, tagged with the attributes you set: `project-type`, `team`, and optionally `application`.
- **Its environments**, from the list on the form, each with its own separation of duty and decommission protection.
- **A deploy group**, e.g. *Billing Deployers*, that can view the project and deploy in the environments under **Pipeline deploys to**. The application's Git repository bundle puts its pipeline's service account in this group, so merges ship to those environments and nowhere else. Add people to it in Massdriver.

## How it connects

The project resource it produces carries the project's identifier, its environments and the deploy group. The Git repository bundle reads it to point its pipeline at the project. The codebase bundle reads it to share the codebase with the project's environments.

The project's environments start empty. Their defaults (the AWS credential, VPC, DNS zone, cluster and codebase) are set on each environment after this deploys; Massdriver's Terraform provider can't set environment defaults yet.

## Attributes

Each attribute key must be defined in the organization before a project can carry it, or the deploy fails. Leave a field empty to leave its attribute off. See the catalog's README for what each attribute is for.

## Changing environments

Adding an environment to the list creates it. Removing one deletes it, which fails while anything in it is still deployed: decommission the environment first.

## Decommissioning

Decommissioning deletes the project, its environments and the deploy group. It fails while anything in the project is still deployed, which keeps a running application from losing its project underneath it.
