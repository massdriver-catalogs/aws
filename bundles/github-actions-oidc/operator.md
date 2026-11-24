---
templating: mustache
---
# GitHub Actions OIDC

## Deploy fails with EntityAlreadyExists

The account already has a GitHub OIDC provider, created by hand or by another tool. Turn on **Adopt the existing provider** and redeploy:

```bash
mass instance deploy {{id}} --patch '.adopt_existing_provider = true' -m "Adopt the existing provider" --follow
```

## A workflow fails with "Not authorized to perform sts:AssumeRoleWithWebIdentity"

The provider is fine; the role's trust policy doesn't match the workflow. See the repository's runbook: the role only trusts its own repository's default branch.
