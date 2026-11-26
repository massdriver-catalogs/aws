---
templating: mustache
---
# Codebase

{{#resources.codebase.repository.url}}
**URL:** {{resources.codebase.repository.url}}

{{/resources.codebase.repository.url}}
{{#resources.codebase}}
- **Registry:** `{{resources.codebase.registry.url}}`, {{resources.codebase.registry.region}}
{{#resources.codebase.repository}}
- **Repository:** `{{resources.codebase.repository.full_name}}`, branch `{{resources.codebase.repository.default_branch}}`
{{/resources.codebase.repository}}
{{/resources.codebase}}
- **Shared with the project:** {{#params.share_with_project}}on{{#dependencies.project}}, `{{dependencies.project.identifier}}`{{/dependencies.project}}{{/params.share_with_project}}{{^params.share_with_project}}off{{/params.share_with_project}}

{{#dependencies.project}}
## Set it as the project's default

Sharing makes the codebase visible to the project; each environment still needs it as its default.

```bash
mass resource list --type aws-codebase --search "{{dependencies.registry.name}}"
{{#dependencies.project.environments}}
mass environment default {{id}} <codebase-resource-id>
{{/dependencies.project.environments}}
```

## A bundle in the project can't see the codebase

- **Not shared:** **Share with the project** is off. Turn it on and redeploy.
- **Shared, but the environment isn't in the project:** the grant matches `md-project = {{dependencies.project.identifier}}`. Environments of other projects can't use it.
- **Shared, but not the default:** set it as the environment's default, above.

## Deploy fails sharing the resource

The Massdriver Service Account credential can't share resources. It needs `resource:grant`. Put the service account in Organization Admin, which has it.
{{/dependencies.project}}
{{^dependencies.project}}
## A runtime can't pull its image

The codebase is linked on this canvas, not shared. Link it to the app's **codebase** slot and deploy the app; the app's role gets the registry's pull policy.

## Deploy fails: Share with the project needs the Massdriver project

**Share with the project** is on, but no project is connected. Turn it off to link the codebase here, or connect the project and the Massdriver Service Account credential.
{{/dependencies.project}}
