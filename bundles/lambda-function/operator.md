---
templating: mustache
---
# Lambda Function

## Ship your app

Until it has an image, the function runs a placeholder. Try it:

```bash
curl -s {{dependencies.api.endpoint}}/
```

### 1. Write a Dockerfile

The function runs on arm64. This example uses the AWS Lambda base image for Python:

```dockerfile
FROM public.ecr.aws/lambda/python:3.13
COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install -r requirements.txt
COPY app.py ${LAMBDA_TASK_ROOT}/
CMD ["app.handler"]
```

```python
# app.py
import json

def handler(event, context):
    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"hello": event["rawPath"]}),
    }
```

Other languages have base images too: `public.ecr.aws/lambda/nodejs`, `java`, `dotnet`, `ruby`, and `provided` for Go or Rust. For a normal web server (Express, FastAPI, Rails), add the [Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter) to your image instead.

{{#dependencies.codebase}}
### 2. Build and push the image

```bash
TAG=$(git rev-parse --short HEAD)
IMAGE={{dependencies.codebase.registry.url}}:$TAG

aws ecr get-login-password --region {{dependencies.codebase.registry.region}} \
  | docker login --username AWS --password-stdin {{dependencies.codebase.registry.registry_id}}.dkr.ecr.{{dependencies.codebase.registry.region}}.amazonaws.com

docker build --platform linux/arm64 --provenance=false -t $IMAGE .
docker push $IMAGE
```

Push a new tag for every change. The function only runs a new image after you deploy it.

### 3. Deploy it

```bash
mass instance deploy {{id}} --patch ".image_uri = \"$IMAGE\"" -m "Ship $TAG"
curl -s {{dependencies.api.endpoint}}/
```
{{/dependencies.codebase}}
{{^dependencies.codebase}}
### 2. Build and push the image

No codebase is connected, so there's no ECR repository to push to. Connect the codebase (it's usually the environment default), redeploy, and this section shows the exact commands.
{{/dependencies.codebase}}

To go back to the placeholder: `mass instance deploy {{id}} --patch '.image_uri = ""' -m "Back to placeholder"`.

### 4. Add routes

Each route is a method and a path. `{id}` captures one path segment and `{proxy+}` captures the rest.

```bash
mass instance deploy {{id}} --patch '.routes = ["GET /items", "GET /items/{id}", "POST /items"]' -m "Item routes"
```

Your code reads the matched route from `event["routeKey"]` and the captured values from `event["pathParameters"]`.

### 5. Give it a database

The function has no database of its own. Your app's bundle declares one and names the variables it wants:

```yaml
dependencies:
  db:
    resource_type: aws-postgres@0.0.0
    required: true
app:
  runtime: lambda-function
  envs:
    PGHOST: .dependencies.db.hostname
    PGUSER: .dependencies.db.username
    PGPASSWORD: .dependencies.db.password
```

Publish the app, link the database and the VPC to it on the canvas (the database only listens inside the VPC) and deploy. The function joins the database's security group and gets its policies. Caches, tables, buckets and queues work the same way.

### 6. Use your own domain

{{#dependencies.api.domain}}
The API already answers on `https://{{dependencies.api.domain}}`.
{{/dependencies.api.domain}}
{{^dependencies.api.domain}}
On the HTTP API, set **Subdomain** (for example `api`) and make sure the environment's DNS zone is connected to it. Deploy the API, then redeploy this function so it sees the new address. The API then answers on `https://<subdomain>.<zone domain>`.
{{/dependencies.api.domain}}

## Read the logs

```bash
aws logs tail /aws/lambda/{{id}} --region {{dependencies.api.region}} --since 15m --follow
```

## 5xx from the API, or the errors alarm

Find the failing invocations:

```bash
aws logs filter-log-events --region {{dependencies.api.region}} --log-group-name /aws/lambda/{{id}} \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) --filter-pattern '?ERROR ?"Task timed out"' \
  --query 'events[].message' --output text | tail -20
```

- **`Task timed out after N seconds`:** raise **Timeout (seconds)**, or make the work smaller. Requests through the API can't run past 30 seconds; send long work to a queue.
- **`Runtime exited` or `out of memory`:** raise **Memory (MB)**.
- **`AccessDeniedException` on DynamoDB, S3 or SQS:** the resource isn't linked to this function, or was linked after the last deploy. Link it and redeploy.
- **`502` with no error in the function's log:** the response isn't in the API's format. Return `statusCode`, `headers` and `body`, with `body` as a string.
- **A stack trace from your code:** fix it and ship a new image.

Call the function directly, without the API:

```bash
aws lambda invoke --region {{dependencies.api.region}} --function-name {{id}} \
  --payload '{"version":"2.0","routeKey":"GET /","rawPath":"/","requestContext":{"http":{"method":"GET","path":"/"}}}' \
  --cli-binary-format raw-in-base64-out /dev/stdout
```

## Slow first request (cold start)

The first request after a quiet period, or after a deploy, starts a new copy of the function. Find how long the start took:

```bash
aws logs filter-log-events --region {{dependencies.api.region}} --log-group-name /aws/lambda/{{id}} \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) --filter-pattern '"initDurationMs"' \
  --query 'events[].message' --output text | tail -5
```

- **Large image:** start time grows with image size. Use a slim base image and leave build tools out of the final image.
- **Slow setup code:** code outside the handler runs on every cold start. Open database connections lazily.
- **Small memory:** CPU grows with **Memory (MB)**, so more memory also starts faster.

## Can't reach the database or cache

The request hangs until the timeout, or the placeholder says `unreachable`.

{{#dependencies.network}}
Check the function is in the VPC with the right security groups:

```bash
aws lambda get-function-configuration --region {{dependencies.api.region}} --function-name {{id}} \
  --query 'VpcConfig.[VpcId,SecurityGroupIds,SubnetIds]'
```

- **`VpcId` is empty:** the database or cache was linked after the last deploy. Redeploy this function.
- **The client security group is missing:** the database was replaced and has a new one. Redeploy this function.
- **Connection refused or a TLS error on the cache:** use `rediss://` (with two s). The cache only accepts TLS.
- **`password authentication failed`:** the password changed. Redeploy this function to pick up the new one.
{{/dependencies.network}}
{{^dependencies.network}}
No VPC is connected, so the function can't reach anything inside it. Link the VPC to this function and redeploy.
{{/dependencies.network}}

## Image won't deploy

The deploy fails while updating the function.

- **`AccessDeniedException` or `not authorized to perform ecr:BatchGetImage`:** the image is in a repository the function can't pull from. Push to the codebase's repository, which allows it. An image from another account needs that repository to allow Lambda to pull.
- **`Source image ... does not exist` or `manifest unknown`:** the tag isn't in the repository. Check it:

  ```bash
  aws ecr describe-images --region {{dependencies.api.region}} --repository-name <repository> --image-ids imageTag=<tag>
  ```

- **`image manifest ... media type ... is not supported`:** Docker added a build attestation. Rebuild with `--provenance=false`.
- **`exec format error` or `InvalidImage` at start:** the image isn't arm64. Rebuild with `--platform linux/arm64`.
- **The repository is in another region:** Lambda only pulls from ECR in its own region, {{dependencies.api.region}}.

{{#params.consume_queue}}
## Queue messages pile up

```bash
aws lambda list-event-source-mappings --region {{dependencies.api.region}} --function-name {{id}} \
  --query 'EventSourceMappings[].[State,StateTransitionReason,LastProcessingResult]'
```

- **`Disabled` or `PROBLEM: ...`:** the reason says what's wrong; usually a missing permission. Redeploy to reattach the queue's policies.
- **Messages go to the dead-letter queue:** the function fails on them. Read the logs above.
- **Deploy fails with `visibility timeout ... less than function timeout`:** lower **Timeout (seconds)** or raise the queue's visibility timeout.
{{/params.consume_queue}}
