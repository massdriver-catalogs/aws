# Fauxcel Static Site

A static site: whatever is in its bucket, served over HTTPS on the site's endpoint. `/docs/` serves `docs/index.html`, a path with no extension falls back to `index.html` so single-page apps route on the client, and `404.html` is used when it exists.

## Deploy

Build, then upload. That's the whole deploy.

```bash
npm run build
aws s3 sync dist/ s3://<site bucket>/ --delete
```

Files under `assets/` or `_next/static/` are cached for a year, because build tools put a hash in their names. Everything else is revalidated on every request, so a new upload shows at once.

The function is the same for every site: a small Python file server, built once into the template's image repository.
