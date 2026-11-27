# ECS Scaling Policy

An IAM policy for an app that starts and stops other ECS services, such as a server that puts idle workers to sleep and wakes them when someone needs them. It covers the services on one cluster whose names start with a prefix, and allows two things on them:

- `ecs:DescribeServices`, to see how many tasks each one wants and runs.
- `ecs:UpdateService`, only to change the task count.

Calls that would also change a service's task definition, capacity provider, subnets, public IP or ECS Exec setting are denied. A task definition carries its own IAM role, so swapping one in would give the service another app's permissions.

The policy is attached to nothing by itself. An app on the `ecs-service` runtime declares an `aws-iam-policy` dependency, and the runtime attaches what's connected there to the app's task role.

```yaml
dependencies:
  lab_power:
    resource_type: aws-iam-policy@0.0.0
    required: false
app:
  runtime: ecs-service
```

Services are named after their Massdriver instance, `<project>-<environment>-<component>-<suffix>`, so `labs-` covers every service in a project called `labs`, and nothing else.

## Cost

Free. IAM policies cost nothing.
