# Connect your AWS account in the AWS Console

Massdriver signs an identity token for every deployment. Your AWS account trusts those tokens through an OIDC provider, and lets them assume a role. There are no keys to store or rotate.

You need your Massdriver organization ID; `mass whoami` shows it. Below it's written as `ORG_ID`.

1. Open **IAM → Identity providers**. If `api.massdriver.cloud` is already listed, open it, choose **Add audience**, enter `massdriver:ORG_ID`, and skip to step 3.
2. Choose **Add provider**, then **OpenID Connect**. Enter the provider URL `https://api.massdriver.cloud` and the audience `massdriver:ORG_ID`, and click **Add provider**.
3. Open **IAM → Roles → Create role** and choose **Web identity**. Pick `api.massdriver.cloud` as the identity provider and `massdriver:ORG_ID` as the audience. Click **Next**.
4. Search for and tick **AdministratorAccess**. Bundles create networks, databases, IAM roles and everything else apps run on, so it needs it. Click **Next**.
5. Name the role `massdriver` and click **Create role**.
6. Open the role, go to **Trust relationships → Edit trust policy**, and add this line inside `StringEquals`, next to the `aud` line, so only your organization's tokens are accepted. Click **Update policy**.

   ```json
   "api.massdriver.cloud:sub": "org:ORG_ID"
   ```

7. Copy the **ARN** at the top of the role's page.

Paste the ARN into **Role ARN** and leave **Token level** on **Organization**.
