# Connect your AWS account with the AWS CLI

Massdriver signs an identity token for every deployment. Your AWS account trusts those tokens through an OIDC provider, and lets them assume a role. There are no keys to store or rotate.

You need the AWS CLI, signed in to the account you'll deploy into, and the [mass CLI](https://docs.massdriver.cloud/reference/cli/overview), signed in to your Massdriver organization.

## 1. Get your organization ID

```bash
ORG_ID=$(mass whoami -o json | jq -r .organization.id)
echo "$ORG_ID"
```

## 2. Trust Massdriver's identity tokens

An AWS account has one OIDC provider per issuer. Create it, or add your organization to it if another organization already uses this account:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PROVIDER_ARN=arn:aws:iam::$ACCOUNT_ID:oidc-provider/api.massdriver.cloud

aws iam create-open-id-connect-provider \
  --url https://api.massdriver.cloud \
  --client-id-list "massdriver:$ORG_ID" \
|| aws iam add-client-id-to-open-id-connect-provider \
  --open-id-connect-provider-arn "$PROVIDER_ARN" \
  --client-id "massdriver:$ORG_ID"
```

## 3. Create the role

The role accepts organization tokens from your organization only:

```bash
aws iam create-role \
  --role-name massdriver \
  --description "Massdriver provisioning" \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": { \"Federated\": \"$PROVIDER_ARN\" },
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": {
        \"StringEquals\": {
          \"api.massdriver.cloud:aud\": \"massdriver:$ORG_ID\",
          \"api.massdriver.cloud:sub\": \"org:$ORG_ID\"
        }
      }
    }]
  }"
```

To give one project its own role instead, use the subject `org:$ORG_ID:project:<project>` and the token level `project` in step 5.

## 4. Give it permission to build

Bundles create networks, databases, IAM roles and everything else apps run on, so the role needs administrator access.

```bash
aws iam attach-role-policy \
  --role-name massdriver \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

## 5. Add it to Massdriver

```bash
ROLE_ARN=$(aws iam get-role --role-name massdriver --query Role.Arn --output text)

cat > aws-credential.json <<EOF
{ "arn": "$ROLE_ARN", "token_level": "organization" }
EOF

mass resource create -n "AWS $ACCOUNT_ID" -t aws-iam-role -f aws-credential.json
```

It prints the new resource's ID. Make it the default in each environment that deploys into this account:

```bash
mass environment default <project>-<environment> <resource-id>
```
