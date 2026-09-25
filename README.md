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

## Custom domain

Set in `config/common.json` under `website`: `domain_name`, `dns_provider` and `attach_domain`.

**`dns_provider: "external"`** (default; e.g. Cloudflare — no API tokens stored, records added by hand):
1. `attach_domain: false` — apply creates only the ACM certificate. Add the `acm_validation_records`
   output as CNAMEs at your DNS provider (DNS only, no proxy).
2. `attach_domain: true` — apply waits until ACM issues the certificate, then adds the domain (apex and
   `www`) to CloudFront. Add the `dns_records_to_add` output as CNAMEs (DNS only) pointing at the
   CloudFront domain.
3. Set the website repo variable `SITE_URL` to `https://<domain>` and re-run its deploy.

**`dns_provider: "route53"`** — Terraform also creates the hosted zone and all records. Set the zone's
`name_servers` output at the registrar (Route 53 registration creates its own zone; point it at ours).

## Notes

- The bucket is private, reachable only through CloudFront (OAC). A CloudFront Function maps `/about/` → `/about/index.html`.
- Plan role is read-only and trusts only pull-request tokens; apply role trusts only the `prod` environment;
  the site deploy role trusts only the website repo's deploy branch.
- Pin/commit `.terraform.lock.hcl` in `stacks/website` after the first `terraform init`.
