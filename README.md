# sloud-solutions-infra

Terraform for hosting [sloud-solutions-website](https://github.com/sloud-solutions/sloud-solutions-website)
on **S3 + CloudFront** (region `us-east-1`), deployed by GitHub Actions using **OIDC** — no access
keys or passwords are stored anywhere.

## Layout

| Path | Purpose |
|---|---|
| `config/` | Single source of truth for inputs: `common.json` + `<env>.json`, checked by `schema.json` |
| `scripts/render-config.sh` | Merges the JSON and renders `stack.auto.tfvars.json`, `backend.hcl` (needs `jq`) |
| `modules/` | Reusable modules: `s3-site-bucket`, `cloudfront`, `acm-certificate`, `route53-zone`, `route53-records`, `github-oidc-role` |
| `stacks/website/` | Root module that wires the modules together |
| `bootstrap/` | One-time admin stack: state bucket, GitHub OIDC provider, plan/apply roles |
| `.github/workflows/` | `plan.yml` (PRs), `apply.yml` (main), `_terraform.yml` (shared) |

## How inputs flow

```
config/common.json ┐
                   ├─ render-config.sh ─► .rendered/stack.auto.tfvars.json ─► terraform plan -var-file
config/<env>.json  ┘                   └► .rendered/backend.hcl            ─► terraform init -backend-config
```

Nothing environment-specific lives in `.tf` files. Run-time values (e.g. the git SHA) arrive as `TF_VAR_*`.
To add an environment: add `config/<env>.json` and list it in the workflow matrix.

## First-time setup

1. **Bootstrap** (admin, short-lived SSO credentials, local state):
   ```bash
   scripts/render-config.sh prod .rendered
   cd bootstrap
   terraform init
   terraform apply -var-file=../.rendered/bootstrap.auto.tfvars.json
   ```
2. In this GitHub repo set **variables** (not secrets — none are sensitive):
   `AWS_REGION=us-east-1`, `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN` (from the bootstrap outputs).
3. Create the GitHub **Environment** `prod` with required reviewers (the apply role trusts only it).
4. Push to `main` (or run the *apply* workflow). Copy the `site_deploy_role_arn`,
   `bucket_name` and `cloudfront_distribution_id` outputs into the website repo as variables; its workflow
   builds, assumes that role via OIDC, runs `aws s3 sync dist/ s3://<bucket> --delete`, then invalidates CloudFront.

The bucket name in `config/common.json` (`backend.bucket`) must be globally unique — change it before bootstrapping if taken.

## Adding the custom domain later

1. Set `website.domain_name` (e.g. `"example.com"`) in `config/common.json` or `config/prod.json`.
2. Apply. The hosted zone is created first; the ACM certificate then waits for DNS validation.
   While it waits, set the zone's `name_servers` output at your registrar (if you registered the
   domain in Route 53, update the domain's nameservers to this zone's — registration creates its own zone).
3. Once validated, CloudFront gets the alias and Route 53 gets A/AAAA records (apex and `www`).

## Notes

- The bucket is private, reachable only through CloudFront (OAC). A CloudFront Function maps `/about/` → `/about/index.html`.
- Plan role is read-only and trusts only pull-request tokens; apply role trusts only the `prod` environment;
  the site deploy role trusts only the website repo's deploy branch.
- Pin/commit `.terraform.lock.hcl` in `stacks/website` after the first `terraform init`.
