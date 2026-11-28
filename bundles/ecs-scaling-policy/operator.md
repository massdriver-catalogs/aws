---
templating: mustache
---
# ECS Scaling Policy

{{#resources.policy}}
- **Policy:** `{{resources.policy.arn}}`
{{/resources.policy}}
- **Covers:** services named `{{params.service_name_prefix}}*` on cluster `{{dependencies.cluster.name}}`, {{dependencies.cluster.region}}
- **Allows:** `ecs:DescribeServices`, and `ecs:UpdateService` for the task count only

## The app gets AccessDeniedException on UpdateService

- **The service's name doesn't start with `{{params.service_name_prefix}}`**, or it's on another cluster. Check the name in the error.
- **The call changes more than the task count**, such as its task definition or subnets. That is denied on purpose. Deploy the service from Massdriver instead.
- **The app's role doesn't have the policy.** Connect this to the app and deploy the app.

```bash
aws iam list-entities-for-policy --policy-arn {{resources.policy.arn}} --query 'PolicyRoles[].RoleName'
```

## See what it allows

```bash
aws iam get-policy-version --policy-arn {{resources.policy.arn}} \
  --version-id $(aws iam get-policy --policy-arn {{resources.policy.arn}} --query Policy.DefaultVersionId --output text)
```
