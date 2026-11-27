# Fauxcel Functions

The server side of a Fauxcel site: one arm64 Lambda function answering every route on the environment's endpoint. Next.js, Remix, SvelteKit and Astro builds run on it through the [Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter); static files ship inside the image and are served by the same function. Until it has an image, a placeholder echoes each request.

| Variable | Set when |
|---|---|
| `KV_TABLE` | KV is connected. The function can read and write it. |
| `BLOB_BUCKET` | Blob is connected. The function can read and write it. |
