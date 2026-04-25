# AWS Serverless Deployment — LibreChat

This directory contains the complete AWS SAM infrastructure-as-code for deploying LibreChat on AWS serverless services.

## Architecture

- **API**: Lambda + Lambda Web Adapter (Express runs unchanged)
- **Frontend**: CloudFront + S3 (OAC)
- **Database**: Amazon DocumentDB (provisioned or serverless)
- **Cache**: Amazon ElastiCache (Valkey 7.2)
- **Search**: MeiliSearch on ECS Fargate + EFS (opt-in)
- **MCP Servers**: Lambda functions inside the VPC
- **Secrets**: AWS Secrets Manager + SSM Parameter Store
- **Email**: Amazon SES
- **Domain**: Route 53 + ACM
- **Security**: WAF on CloudFront, VPC private subnets, least-privilege IAM
- **Observability**: CloudWatch dashboard, alarms, X-Ray tracing

## Prerequisites

- [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html) installed
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with appropriate credentials
- Node.js 22.x
- Docker (for `sam build --use-container` if needed)

## Directory Structure

```
aws-infra/
├── template.yaml              # Root SAM template (nested stacks)
├── samconfig.toml             # Per-environment deploy parameters
├── nested/                    # Nested CloudFormation stacks
│   ├── vpc.yaml               # VPC, subnets, NAT gateways, security groups
│   ├── database.yaml          # DocumentDB cluster
│   ├── cache.yaml             # ElastiCache (Valkey/Redis)
│   ├── storage.yaml           # S3 uploads bucket
│   ├── frontend.yaml          # S3 + CloudFront + WAF + ACM + Route 53
│   ├── secrets.yaml           # Secrets Manager + SSM parameters
│   ├── api-lambda.yaml        # Lambda API + API Gateway
│   ├── ses.yaml               # SES email identity + DKIM
│   ├── observability.yaml     # CloudWatch dashboard, alarms, X-Ray
│   ├── meilisearch.yaml       # ECS Fargate MeiliSearch (optional)
│   ├── pipeline.yaml          # CodePipeline (optional)
│   └── github-oidc.yaml       # GitHub Actions OIDC provider + deploy role
├── mcp/                       # MCP Lambda functions
│   ├── template.yaml
│   └── handlers/
├── scripts/                   # Deployment helper scripts
│   ├── build-frontend.sh
│   ├── invalidate-cf.sh
│   ├── seed-docdb.sh
│   ├── smoke-test.sh
│   └── sync-secrets.sh
├── layers/                    # Lambda layers
│   └── docdb-ca/              # DocumentDB CA bundle
└── lambda-bootstrap/          # Cold-start secret loader
    └── init-secrets.js
```

## Quick Start (Dev Environment)

### 1. Set up the OIDC deploy role (one-time per account)

```bash
aws cloudformation deploy \
  --template-file aws-infra/nested/github-oidc.yaml \
  --stack-name librechat-github-oidc \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubOrg=YOUR_ORG RepositoryName=LibreChat Environment=dev
```

### 2. Download the DocumentDB CA bundle

```bash
bash aws-infra/layers/docdb-ca/download-ca.sh
```

### 3. Build and deploy

```bash
cd aws-infra
sam build --config-env dev
sam deploy --config-env dev
```

### 4. Sync secrets from infrastructure outputs

```bash
bash aws-infra/scripts/sync-secrets.sh dev --profile personal
```

This auto-generates secure random values for passwords and tokens (DOCDB_PASSWORD, REDIS_AUTH_TOKEN, JWT_SECRET, etc.) and assembles MONGO_URI and REDIS_URI from the deployed DocumentDB and ElastiCache endpoints. Only placeholder values are overwritten — any keys you've already manually set are preserved.

### 5. Sync frontend assets

```bash
bash aws-infra/scripts/build-frontend.sh dev --profile personal
```

### 6. Seed the database

```bash
bash aws-infra/scripts/seed-docdb.sh dev --profile personal
```

### 7. Run smoke tests

```bash
bash aws-infra/scripts/smoke-test.sh dev --profile personal
```

## Environment Configuration

The `samconfig.toml` defines three environments:

| Environment | Stack Name | Key Differences |
|---|---|---|
| `dev` | `librechat-dev` | Single-AZ, serverless DocumentDB, small cache nodes |
| `staging` | `librechat-staging` | Single-AZ, provisioned DocumentDB (db.t3.medium) |
| `prod` | `librechat-prod` | Multi-AZ, provisioned DocumentDB (db.r6g.large), MeiliSearch enabled, 3 GB Lambda |

Deploy to a specific environment:

```bash
sam build --config-env prod
sam deploy --config-env prod
```

## Post-Deploy Configuration

### Update Secrets

After the first deploy, run the secrets sync script to auto-populate connection URIs and generate secure tokens:

```bash
bash aws-infra/scripts/sync-secrets.sh dev --profile personal
```

The script:
- Generates secure random values for any keys still set to placeholders (DOCDB_PASSWORD, REDIS_AUTH_TOKEN, JWT_SECRET, JWT_REFRESH_SECRET, CREDS_KEY, CREDS_IV, MEILI_MASTER_KEY)
- Assembles MONGO_URI from the DocumentDB endpoint + generated credentials
- Assembles REDIS_URI from the ElastiCache endpoint + generated auth token
- Preserves any keys you've already manually configured

You still need to manually set external API keys:

```bash
# Example: update individual keys via the AWS CLI
aws secretsmanager get-secret-value --secret-id librechat/dev/secrets --query SecretString --output text \
  | node -e "let s=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); s.OPENAI_API_KEY='sk-...'; process.stdout.write(JSON.stringify(s))" \
  | xargs -0 aws secretsmanager put-secret-value --secret-id librechat/dev/secrets --secret-string
```

### Custom Domain

To use a custom domain, deploy with:

```bash
sam deploy --config-env prod \
  --parameter-overrides "Environment=prod CustomDomain=chat.example.com HostedZoneId=Z1234567890"
```

### Enable MeiliSearch

```bash
sam deploy --config-env prod \
  --parameter-overrides "Environment=prod EnableMeiliSearch=true"
```

## CI/CD

### GitHub Actions (default)

The workflow at `.github/workflows/deploy.yml` handles automated deployments. Set the `AWS_DEPLOY_ROLE_ARN` secret in each GitHub environment (dev/staging/prod) using the role ARN from the OIDC stack output.

### AWS CodePipeline (alternative)

Deploy with `CIPlatform=codepipeline`:

```bash
sam deploy --config-env prod \
  --parameter-overrides "CIPlatform=codepipeline CodeStarConnectionArn=arn:aws:... RepositoryId=my-org/LibreChat"
```

## Adding MCP Servers

See [scripts/add-mcp-server.md](scripts/add-mcp-server.md) for step-by-step instructions.

## AWS CLI Profile

All scripts accept an optional `--profile` flag to specify which AWS CLI profile to use:

```bash
bash aws-infra/scripts/build-frontend.sh dev --profile personal
bash aws-infra/scripts/invalidate-cf.sh prod --profile work
bash aws-infra/scripts/sync-secrets.sh dev --profile personal
```

If omitted, the default AWS CLI profile/credentials are used.

## Useful Commands

```bash
# Validate all templates
cfn-lint aws-infra/template.yaml aws-infra/nested/*.yaml aws-infra/mcp/template.yaml

# Invalidate CloudFront cache
bash aws-infra/scripts/invalidate-cf.sh dev --profile personal

# Sync secrets after infrastructure changes
bash aws-infra/scripts/sync-secrets.sh dev --profile personal

# View stack outputs
aws cloudformation describe-stacks --stack-name librechat-dev --query "Stacks[0].Outputs" --profile personal
```
