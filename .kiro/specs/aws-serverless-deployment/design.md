# Design Document: AWS Serverless Deployment for LibreChat

## Overview

This document describes the technical design for deploying LibreChat on AWS using serverless and managed services. LibreChat is a full-stack AI chat platform with a Node.js/Express API (`/api`), a React frontend (`/client`), MongoDB-compatible persistence, Redis caching, S3 file storage, MCP server support, and integrations with multiple AI providers.

The deployment uses AWS SAM as the primary IaC tool, with the following core decisions:

- **API**: Lambda + Lambda Web Adapter (zero code changes to Express app)
- **Frontend**: CloudFront + S3 (OAC)
- **Database**: Amazon DocumentDB (MongoDB-compatible)
- **Cache/Sessions**: Amazon ElastiCache (Valkey/Redis)
- **Search**: MeiliSearch on ECS Fargate + EFS (opt-in via `EnableMeiliSearch` parameter)
- **MCP Servers**: AWS Lambda functions inside the VPC (stateless)
- **Secrets**: AWS Secrets Manager
- **Email**: Amazon SES
- **Domain**: Route 53 + ACM
- **Security**: WAF on CloudFront, VPC private subnets, least-privilege IAM
- **Environments**: `dev`, `staging`, `prod`

---

## Architecture

### High-Level Topology

```mermaid
graph TB
    User["User Browser"]
    DNS["Route 53\n(Alias A record)"]
    WAF["AWS WAF\n(AWSManagedRulesCommonRuleSet)"]
    CF["CloudFront Distribution\n(HTTPS-only, TLSv1.2_2021)"]
    S3FE["S3 Bucket\n(Frontend Assets, OAC)"]
    APIGW["API Gateway HTTP API (v2)"]
    LambdaAPI["Lambda Function\n(LibreChat API + LWA)"]
    DocDB["Amazon DocumentDB\n(writer + reader, private)"]
    ElastiCache["ElastiCache\n(Valkey/Redis, private)"]
    S3UL["S3 Bucket\n(User Uploads)"]
    SM["Secrets Manager"]
    SES["Amazon SES"]
    MeiliECS["ECS Fargate\n(MeiliSearch, optional)"]
    EFS["Amazon EFS\n(MeiliSearch index)"]
    MCPLambda["MCP Lambda Functions\n(per MCP server, VPC)"]
    CW["CloudWatch\n(Logs, Metrics, Alarms)"]
    XRay["AWS X-Ray"]
    SNS["SNS Topic\n(Alerts)"]

    User --> DNS --> WAF --> CF
    CF -->|"/api/*"| APIGW --> LambdaAPI
    CF -->|"/*"| S3FE

    LambdaAPI -->|"VPC private"| DocDB
    LambdaAPI -->|"VPC private"| ElastiCache
    LambdaAPI -->|"IAM role"| S3UL
    LambdaAPI -->|"SDK"| SM
    LambdaAPI -->|"SDK"| SES
    LambdaAPI -->|"VPC private"| MeiliECS
    LambdaAPI -->|"VPC private"| MCPLambda
    MeiliECS --> EFS

    LambdaAPI --> CW
    LambdaAPI --> XRay
    APIGW --> CW
    CW --> SNS
```

### VPC Network Topology

The VPC topology is controlled by the `MultiAZ` SAM parameter (default: `true`).

**Multi-AZ (default, `MultiAZ=true`)** — two public subnets, two private subnets, two NAT Gateways for full HA:

```mermaid
graph TB
    subgraph VPC["VPC (10.0.0.0/16) — MultiAZ=true"]
        subgraph AZ1["Availability Zone 1"]
            PubSub1["Public Subnet\n10.0.0.0/24"]
            PrivSub1["Private Subnet\n10.0.2.0/24"]
            NAT1["NAT Gateway"]
        end
        subgraph AZ2["Availability Zone 2"]
            PubSub2["Public Subnet\n10.0.1.0/24"]
            PrivSub2["Private Subnet\n10.0.3.0/24"]
            NAT2["NAT Gateway"]
        end
        IGW["Internet Gateway"]
        LambdaAPI["Lambda (API)\nSG: sg-lambda"]
        MCPLambda["Lambda (MCP)\nSG: sg-mcp"]
        DocDB["DocumentDB\nSG: sg-docdb\nPort 27017"]
        ElastiCache["ElastiCache\nSG: sg-redis\nPort 6379"]
        MeiliECS["ECS Fargate (Meili)\nSG: sg-meili\nPort 7700"]
    end

    PubSub1 --> NAT1 --> IGW
    PubSub2 --> NAT2 --> IGW
    PrivSub1 --> NAT1
    PrivSub2 --> NAT2
    LambdaAPI --> DocDB
    LambdaAPI --> ElastiCache
    LambdaAPI --> MeiliECS
    LambdaAPI --> MCPLambda
```

**Single-AZ (`MultiAZ=false`)** — one public subnet, one private subnet, one NAT Gateway. Reduces cost but eliminates high availability:

```mermaid
graph TB
    subgraph VPC["VPC (10.0.0.0/16) — MultiAZ=false"]
        subgraph AZ1["Availability Zone 1"]
            PubSub1["Public Subnet\n10.0.0.0/24"]
            PrivSub1["Private Subnet\n10.0.2.0/24"]
            NAT1["NAT Gateway"]
        end
        IGW["Internet Gateway"]
        LambdaAPI["Lambda (API)\nSG: sg-lambda"]
        MCPLambda["Lambda (MCP)\nSG: sg-mcp"]
        DocDB["DocumentDB\n(writer only)\nSG: sg-docdb\nPort 27017"]
        ElastiCache["ElastiCache\n(primary only)\nSG: sg-redis\nPort 6379"]
        MeiliECS["ECS Fargate (Meili)\nSG: sg-meili\nPort 7700"]
    end

    PubSub1 --> NAT1 --> IGW
    PrivSub1 --> NAT1
    LambdaAPI --> DocDB
    LambdaAPI --> ElastiCache
    LambdaAPI --> MeiliECS
    LambdaAPI --> MCPLambda
```

> **Note:** `MultiAZ=false` is suitable for dev/staging environments where cost reduction is preferred over availability. Do not use in production.

### Security Group Rules

| Security Group | Inbound | Outbound |
|---|---|---|
| `sg-lambda` | None (Lambda is invoked by API GW, not via SG) | 443 to 0.0.0.0/0 (AI APIs), 27017 to sg-docdb, 6379 to sg-redis, 7700 to sg-meili, 443 to sg-mcp |
| `sg-docdb` | 27017 from sg-lambda | None |
| `sg-redis` | 6379 from sg-lambda | None |
| `sg-meili` | 7700 from sg-lambda | None |
| `sg-mcp` | 443 from sg-lambda | 443 to 0.0.0.0/0, 27017 to sg-docdb, 6379 to sg-redis |

---

## Components and Interfaces

### 1. Frontend — CloudFront + S3

The React app is built with Vite (`npm run frontend`) and produces static assets in `client/dist`. These are uploaded to a dedicated S3 bucket served exclusively through CloudFront via Origin Access Control (OAC).

**CloudFront Behaviors:**

| Path Pattern | Origin | Cache Policy |
|---|---|---|
| `/api/*` | API Gateway HTTP API | No cache (TTL=0) |
| `/*.js`, `/*.css`, `/*.woff2` | S3 (frontend) | TTL=86400s (versioned assets) |
| `/*` (default) | S3 (frontend) | TTL=0 for `index.html`; SPA fallback via custom error response (403→index.html, 404→index.html) |

**Key settings:**
- `DefaultRootObject: index.html`
- Custom error responses: 403 and 404 → `/index.html` with 200 status (SPA routing)
- `ViewerProtocolPolicy: redirect-to-https`
- `MinimumProtocolVersion: TLSv1.2_2021`
- WAF WebACL attached with `AWSManagedRulesCommonRuleSet`

### 2. API Backend — Lambda + Lambda Web Adapter

The LibreChat Express app (`api/server/index.js`) runs unchanged inside Lambda using the [AWS Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter). LWA acts as a shim that translates Lambda invocation events into HTTP requests forwarded to the Express server on `localhost:3080`.

**Lambda configuration:**
- Runtime: `nodejs20.x`
- Memory: 1024 MB minimum (configurable per environment)
- Timeout: 30 seconds
- Architecture: `x86_64`
- VPC: private subnets, `sg-lambda`
- Response streaming: enabled via `FunctionUrlConfig` with `InvokeMode: RESPONSE_STREAM` for AI token streaming
- Environment variables: loaded from Secrets Manager at cold start

**Lambda Web Adapter setup** (added as a Lambda layer, no code changes):
```
AWS_LAMBDA_EXEC_WRAPPER=/opt/bootstrap
PORT=3080
READINESS_CHECK_PATH=/health
```

The existing `/health` endpoint in `api/server/index.js` serves as the LWA readiness probe.

**API Gateway:**
- Type: HTTP API (v2)
- Integration: Lambda proxy
- Route: `$default` → Lambda ARN
- Payload format: 2.0
- Binary media types: `multipart/form-data`, `application/octet-stream`

**Cold-start secret loading** (via AWS SDK at module init):
```javascript
// Loaded once per execution environment, cached in module scope
const secrets = await secretsManagerClient.getSecretValue({ SecretId: process.env.SECRET_ARN });
Object.assign(process.env, JSON.parse(secrets.SecretString));
```

### 3. Database — Amazon DocumentDB

DocumentDB provides a MongoDB 5.0-compatible API. The LibreChat app connects via Mongoose using the standard `MONGO_URI` environment variable.

**DocumentDB connection string format:**
```
mongodb://username:password@cluster.cluster-xxxx.us-east-1.docdb.amazonaws.com:27017/LibreChat?tls=true&tlsCAFile=/opt/rds-combined-ca-bundle.pem&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false
```

**Important DocumentDB considerations:**
- `retryWrites=false` is required (DocumentDB does not support retryable writes)
- TLS CA bundle must be bundled with the Lambda deployment package at `/opt/rds-combined-ca-bundle.pem`
- Connection pooling: `MONGO_MAX_POOL_SIZE=5` recommended for Lambda (avoid connection exhaustion)
- `MONGO_MAX_IDLE_TIME_MS=45000` to recycle idle connections before Lambda freezes them

The DocumentDB configuration is controlled by two SAM parameters: `DocumentDBMode` and `MultiAZ`.

#### Provisioned mode (`DocumentDBMode=provisioned`, default)

Uses fixed instance types controlled by the `DocumentDBInstanceClass` parameter.

**Multi-AZ (`MultiAZ=true`, default):**
- 1 writer instance + 1 reader instance for HA
- Writer in AZ1, reader in AZ2
- `readPreference=secondaryPreferred` routes reads to the reader

**Single-AZ (`MultiAZ=false`):**
- 1 writer instance only (no reader)
- Reduces cost but eliminates read replica failover
- `readPreference=primary` should be used in the connection string

**Common provisioned settings:**
- Engine: `docdb` (MongoDB 5.0 compatible)
- Instance class: controlled by `DocumentDBInstanceClass` parameter (default: `db.t3.medium`)
- Backup retention: 7 days
- Encryption at rest: KMS CMK
- TLS: enforced via cluster parameter group (`tls: enabled`)

#### Serverless mode (`DocumentDBMode=serverless`)

Uses `AWS::DocDB::DBCluster` with `ServerlessV2ScalingConfiguration`. Ideal for dev/staging environments or workloads with variable traffic patterns.

```yaml
# SAM template excerpt — serverless DocumentDB
DBCluster:
  Type: AWS::DocDB::DBCluster
  Properties:
    ServerlessV2ScalingConfiguration:
      MinCapacity: 0.5   # ACUs
      MaxCapacity: 16    # ACUs
    StorageEncrypted: true
    # ... other properties

DBInstance:
  Type: AWS::DocDB::DBInstance
  Properties:
    DBInstanceClass: db.serverless
    DBClusterIdentifier: !Ref DBCluster
```

- Scales automatically between 0.5 and 16 ACUs based on load
- No reader instance is provisioned in serverless mode (single writer scales vertically)
- Billed per ACU-hour — cost-effective for intermittent or unpredictable workloads
- `MultiAZ` parameter has no effect in serverless mode (single instance)

### 4. Cache — Amazon ElastiCache (Valkey)

ElastiCache provides Redis-compatible caching for sessions, rate-limit counters, and resumable AI streams (via `USE_REDIS=true`).

**Cluster configuration:**
- Engine: Valkey 7.2 (or Redis OSS 7.x)
- Mode: Cluster mode disabled (single shard)
- In-transit encryption: TLS enabled
- At-rest encryption: enabled
- Auth token: stored in Secrets Manager

**HA vs. single-node** is controlled by the `MultiAZ` parameter:

| `MultiAZ` | Nodes | Description |
|---|---|---|
| `true` (default) | 1 primary + 1 replica | Automatic failover; replica in AZ2 |
| `false` | 1 primary only | Lower cost; no replica for failover |

> **Note:** Single-node (`MultiAZ=false`) has no replica for failover. If the primary node fails, ElastiCache will provision a replacement, but there will be a brief downtime window. Use only for dev/staging.

**Node type:** `cache.t4g.small` (dev/staging), `cache.r7g.large` (prod) — controlled by `ElastiCacheNodeType` parameter.

**LibreChat Redis env vars:**
```
USE_REDIS=true
USE_REDIS_STREAMS=true
REDIS_URI=rediss://:authtoken@cluster.xxxx.cache.amazonaws.com:6379
REDIS_USE_ALTERNATIVE_DNS_LOOKUP=true  # required for ElastiCache TLS
```

### 5. File Storage — S3 (Uploads)

A dedicated S3 bucket stores user-uploaded files. The Lambda function uses the AWS SDK (`@aws-sdk/client-s3` + `@aws-sdk/s3-request-presigner`) to generate pre-signed URLs.

**Bucket configuration:**
- Block all public access: enabled
- Versioning: enabled
- Lifecycle policy: transition to S3 Intelligent-Tiering after 30 days
- Server-side encryption: SSE-S3 (or SSE-KMS)
- CORS: configured to allow pre-signed URL uploads from the CloudFront domain

**Bucket naming** includes the AWS account ID to guarantee global uniqueness:
- Uploads bucket: `librechat-uploads-{accountId}-{env}`
- Frontend assets bucket: `librechat-frontend-{accountId}-{env}`

**LibreChat S3 env vars:**
```
AWS_BUCKET_NAME=librechat-uploads-{accountId}-{env}
AWS_REGION=us-east-1
```

The Lambda IAM role grants `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` scoped to `arn:aws:s3:::librechat-uploads-{accountId}-{env}/*`.

### 6. Secrets Management

All secrets are stored in Secrets Manager as a single JSON secret per environment: `librechat/{env}/secrets`.

**Secret JSON structure:**
```json
{
  "MONGO_URI": "mongodb://...",
  "REDIS_URI": "rediss://...",
  "JWT_SECRET": "...",
  "JWT_REFRESH_SECRET": "...",
  "CREDS_KEY": "...",
  "CREDS_IV": "...",
  "OPENAI_API_KEY": "...",
  "ANTHROPIC_API_KEY": "...",
  "MEILI_MASTER_KEY": "...",
  "EMAIL_FROM": "...",
  "GOOGLE_CLIENT_ID": "...",
  "GOOGLE_CLIENT_SECRET": "..."
}
```

Non-secret config values (feature flags, domain names, `librechat.yaml` content) are stored in SSM Parameter Store as `SecureString` under `/librechat/{env}/config/*`.

The Lambda function loads secrets at cold start using the AWS SDK and merges them into `process.env`. The Lambda execution environment caches these for its lifetime, satisfying the rotation requirement (next cold start picks up rotated values).

### 7. MeiliSearch (Optional)

Controlled by the `EnableMeiliSearch` SAM parameter (default: `false`).

When enabled:
- ECS Fargate task running `getmeili/meilisearch:latest`
- Task definition: 0.5 vCPU, 1 GB memory
- EFS volume mounted at `/meili_data` for index persistence
- Service discovery via AWS Cloud Map (internal DNS: `meili.librechat.local:7700`)
- Security group `sg-meili`: inbound 7700 from `sg-lambda` only

When disabled:
- `SEARCH=false` is set in Lambda environment
- No ECS, EFS, or Cloud Map resources are provisioned

### 8. MCP Servers

Each MCP server is deployed as a separate Lambda function inside the VPC. MCP Lambdas are stateless — any shared state is stored in ElastiCache or DocumentDB.

**MCP Lambda configuration:**
- Runtime: `nodejs20.x` (or `python3.12` depending on MCP server)
- VPC: same private subnets as API Lambda
- Security group: `sg-mcp` (inbound 443 from `sg-lambda`)
- Function URL: enabled with `AuthType: AWS_IAM` (invoked by API Lambda using SigV4)
- Timeout: 60 seconds (MCP operations may be long-running)

**API Lambda → MCP Lambda communication:**
The API Lambda calls MCP Lambda function URLs over the VPC using the AWS SDK (`InvokeWithResponseStream` for streaming MCP responses). The `librechat.yaml` config (stored in SSM Parameter Store) maps MCP server names to their Lambda function URLs.

**Adding a new MCP server:**
1. Add a new `AWS::Serverless::Function` resource to the SAM template
2. Update `librechat.yaml` in SSM Parameter Store with the new function URL
3. Deploy the stack — no API Lambda redeployment required

### 9. Email — Amazon SES

LibreChat uses `nodemailer` for transactional email. The SES transport is configured via:
```
EMAIL_SERVICE=SES
AWS_REGION=us-east-1
```

The Lambda IAM role grants `ses:SendEmail` and `ses:SendRawEmail` scoped to the verified SES identity ARN.

Domain verification is performed via Route 53 DNS records (DKIM, SPF, DMARC) as part of the deployment pipeline.

### 10. Custom Domain — Route 53 + ACM

- ACM certificate provisioned in `us-east-1` (required for CloudFront)
- DNS validation via Route 53 CNAME records (automated in SAM/CDK)
- Route 53 A record (alias) pointing to CloudFront distribution
- CloudFront `Aliases`: `["chat.example.com"]`

---

## Data Models

### Secret Structure (Secrets Manager)

```
librechat/{env}/secrets  →  JSON blob (see §6 above)
```

### SSM Parameter Store Layout

```
/librechat/{env}/config/DOMAIN_CLIENT          → https://chat.example.com
/librechat/{env}/config/DOMAIN_SERVER          → https://chat.example.com
/librechat/{env}/config/MEILI_HOST             → http://meili.librechat.local:7700
/librechat/{env}/config/SEARCH                 → true|false
/librechat/{env}/config/librechat_yaml         → (full YAML content)
/librechat/{env}/config/CONSOLE_JSON           → true
/librechat/{env}/config/TRUST_PROXY            → 1
/librechat/{env}/config/UPLOADS_BUCKET         → librechat-uploads-{accountId}-{env}
/librechat/{env}/config/FRONTEND_BUCKET        → librechat-frontend-{accountId}-{env}
```

### CloudFormation Stack Outputs

| Output Key | Description |
|---|---|
| `CloudFrontURL` | CloudFront distribution domain name |
| `APIGatewayURL` | API Gateway invoke URL |
| `FrontendBucketName` | S3 bucket name for frontend assets (`librechat-frontend-{accountId}-{env}`) |
| `UploadsBucketName` | S3 bucket name for user uploads (`librechat-uploads-{accountId}-{env}`) |
| `DocumentDBEndpoint` | DocumentDB cluster endpoint |
| `ElastiCacheEndpoint` | ElastiCache primary endpoint |

### SAM Template Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `Environment` | String | `dev` | Deployment environment (`dev`/`staging`/`prod`) |
| `MultiAZ` | String | `true` | Deploy across two AZs (`true`) or a single AZ (`false`). Single-AZ reduces cost but eliminates HA. |
| `EnableMeiliSearch` | String | `false` | Deploy MeiliSearch on ECS Fargate |
| `CustomDomain` | String | `""` | Custom domain name (e.g., `chat.example.com`) |
| `HostedZoneId` | String | `""` | Route 53 hosted zone ID |
| `LambdaMemorySize` | Number | `1024` | API Lambda memory in MB |
| `DocumentDBMode` | String | `provisioned` | DocumentDB mode: `provisioned` (fixed instance type) or `serverless` (auto-scaling ACUs, ideal for dev/staging or variable workloads) |
| `DocumentDBInstanceClass` | String | `db.t3.medium` | DocumentDB instance class (used only when `DocumentDBMode=provisioned`) |
| `ElastiCacheNodeType` | String | `cache.t4g.small` | ElastiCache node type |
| `CIPlatform` | String | `github-actions` | CI/CD platform: `github-actions` or `codepipeline` |

---

## IaC Structure

The deployment is defined as an AWS SAM application. The repository structure for IaC:

```
aws-infra/
├── template.yaml                  # Root SAM template
├── samconfig.toml                 # SAM CLI config (per-env deploy params)
├── nested/
│   ├── vpc.yaml                   # VPC, subnets, NAT gateways, SGs
│   ├── database.yaml              # DocumentDB cluster + subnet group
│   ├── cache.yaml                 # ElastiCache cluster + subnet group
│   ├── frontend.yaml              # S3 + CloudFront + WAF + ACM + Route53
│   ├── api-lambda.yaml            # Lambda function + API Gateway
│   ├── storage.yaml               # Uploads S3 bucket
│   ├── secrets.yaml               # Secrets Manager + SSM params
│   ├── ses.yaml                   # SES identity + IAM
│   ├── observability.yaml         # CloudWatch dashboard, alarms, X-Ray
│   ├── meilisearch.yaml           # ECS Fargate + EFS (conditional)
│   ├── pipeline.yaml              # CodePipeline (conditional)
│   └── github-oidc.yaml           # GitHub Actions OIDC provider + deploy role
├── mcp/
│   └── template.yaml              # MCP Lambda functions (nested stack)
├── scripts/
│   ├── build-frontend.sh          # npm run frontend + S3 sync
│   ├── seed-docdb.sh              # DocumentDB index creation
│   ├── invalidate-cf.sh           # CloudFront cache invalidation
│   ├── smoke-test.sh              # Post-deploy smoke tests
│   └── add-mcp-server.md          # Guide for adding new MCP servers
├── layers/
│   └── docdb-ca/                  # RDS CA bundle Lambda layer
└── lambda-bootstrap/
    └── init-secrets.js            # Cold-start secret loader
```

**Nested stack approach:** The root `template.yaml` uses `AWS::CloudFormation::Stack` resources to compose nested stacks. This keeps each concern independently deployable and avoids the 500-resource CloudFormation limit.

**`samconfig.toml` example:**
```toml
[dev.deploy.parameters]
stack_name = "librechat-dev"
region = "us-east-1"
parameter_overrides = "Environment=dev EnableMeiliSearch=false LambdaMemorySize=1024"

[prod.deploy.parameters]
stack_name = "librechat-prod"
region = "us-east-1"
parameter_overrides = "Environment=prod EnableMeiliSearch=true LambdaMemorySize=3008 DocumentDBInstanceClass=db.r6g.large"
```

---

## CI/CD Pipeline

The CI/CD platform is controlled by the `CIPlatform` SAM parameter (default: `github-actions`). Both options produce the same deployment outcome; choose based on your team's tooling preferences.

### Option A: GitHub Actions (`CIPlatform=github-actions`)

```mermaid
flowchart LR
    Push["Git push\n(main / release/*)"]
    Lint["Lint & Unit Tests\n(npm test)"]
    BuildFE["Build Frontend\n(npm run frontend)"]
    BuildAPI["Package API\n(sam build)"]
    Deploy["sam deploy\n(--config-env {env})"]
    SeedDB["Seed DocumentDB\n(indexes)"]
    SyncS3["Sync S3\n(frontend assets)"]
    InvalidateCF["Invalidate CloudFront\n(index.html)"]
    Smoke["Smoke Tests\n(/health endpoint)"]

    Push --> Lint --> BuildFE --> BuildAPI --> Deploy
    Deploy --> SeedDB
    Deploy --> SyncS3 --> InvalidateCF
    Deploy --> Smoke
```

**GitHub Actions workflow** (`.github/workflows/deploy.yml`):

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [dev, staging, prod]

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment || 'dev' }}
    permissions:
      id-token: write   # OIDC for AWS auth
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
          aws-region: us-east-1
      - run: npm ci
      - run: npm test --workspace=api
      - run: npm run frontend
      - run: sam build --config-env ${{ inputs.environment || 'dev' }}
      - run: sam deploy --config-env ${{ inputs.environment || 'dev' }} --no-confirm-changeset
      - run: bash aws-infra/scripts/sync-frontend.sh ${{ inputs.environment || 'dev' }}
      - run: bash aws-infra/scripts/invalidate-cf.sh ${{ inputs.environment || 'dev' }}
      - run: bash aws-infra/scripts/smoke-test.sh
```

AWS authentication uses OIDC (no long-lived credentials). A dedicated deploy IAM role with scoped permissions is assumed per environment.

### Option B: AWS CodePipeline (`CIPlatform=codepipeline`)

When `CIPlatform=codepipeline`, a CodePipeline pipeline is provisioned as part of the SAM stack. This keeps all CI/CD infrastructure inside AWS and is useful when GitHub Actions is not available or when tighter AWS-native audit trails are required.

```mermaid
flowchart LR
    Repo["Git Repository\n(GitHub / GitLab / Bitbucket)\nvia CodeStar Connection"]
    Source["Source Stage\n(CodeStar Connections)"]
    Build["Build Stage\n(CodeBuild)"]
    Deploy["Deploy Stage\n(CloudFormation / SAM)"]
    PostDeploy["Post-Deploy Stage\n(CodeBuild)"]
    Artifacts["S3 Artifacts Bucket\nlibrechat-pipeline-{accountId}-{env}"]

    Repo --> Source --> Build --> Deploy --> PostDeploy
    Build -.->|artifacts| Artifacts
    Deploy -.->|artifacts| Artifacts
```

**Pipeline stages:**

1. **Source** — CodeStar Connections integration with an existing Git repository (GitHub, GitLab, or Bitbucket). Triggers on push to the configured branch. The connection ARN is provided as a SAM parameter (`CodeStarConnectionArn`).

2. **Build** — CodeBuild project that:
   - Runs `npm ci` and `npm test --workspace=api` (unit tests)
   - Runs `npm run frontend` (Vite build)
   - Runs `sam build` to produce the Lambda deployment package
   - Uploads build artifacts (frontend dist + SAM build output) to the pipeline artifacts S3 bucket

3. **Deploy** — CloudFormation/SAM deploy action using the `AWS::CodePipeline::Pipeline` CloudFormation deploy action type. Equivalent to `sam deploy --no-confirm-changeset`. For `prod`, an optional manual approval action is inserted before this stage.

4. **Post-Deploy** — CodeBuild project that:
   - Syncs frontend assets to the frontend S3 bucket (`aws s3 sync`)
   - Invalidates the CloudFront distribution cache (`aws cloudfront create-invalidation`)
   - Runs smoke tests (`GET /health`, `GET /api/config`)

**Pipeline artifacts bucket:** `librechat-pipeline-{accountId}-{env}` — dedicated S3 bucket with versioning enabled, server-side encryption (SSE-S3), and a 30-day lifecycle policy for old artifacts.

**IAM role for CodePipeline** (least-privilege):
- `codebuild:StartBuild`, `codebuild:BatchGetBuilds` — scoped to the pipeline's CodeBuild projects
- `cloudformation:CreateChangeSet`, `cloudformation:ExecuteChangeSet`, `cloudformation:DescribeStacks` — scoped to the `librechat-{env}` stack
- `s3:GetObject`, `s3:PutObject` — scoped to the pipeline artifacts bucket
- `codestar-connections:UseConnection` — scoped to the configured CodeStar connection ARN
- `iam:PassRole` — scoped to the CloudFormation deploy role

**SAM parameters added for CodePipeline:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `CIPlatform` | String | `github-actions` | `github-actions` or `codepipeline` |
| `CodeStarConnectionArn` | String | `""` | ARN of the CodeStar Connections connection (required when `CIPlatform=codepipeline`) |
| `RepositoryId` | String | `""` | Repository identifier, e.g. `my-org/librechat` (required when `CIPlatform=codepipeline`) |
| `BranchName` | String | `main` | Branch to trigger the pipeline on |

**Rollback:** CloudFormation automatic rollback is enabled for both options (`--on-failure ROLLBACK`). If any resource update fails, CloudFormation reverts the entire stack to the previous stable state.

---

## Error Handling

### Lambda Cold Start Failures

If Secrets Manager is unreachable at cold start, the Lambda function should fail fast with a clear error log. The Lambda execution environment will be discarded and a new one retried on the next invocation.

```javascript
// Fail fast pattern for secret loading
try {
  const secret = await sm.getSecretValue({ SecretId: process.env.SECRET_ARN }).promise();
  Object.assign(process.env, JSON.parse(secret.SecretString));
} catch (err) {
  console.error('[FATAL] Failed to load secrets:', err.message);
  process.exit(1);
}
```

### DocumentDB Connection Errors

- Mongoose `bufferCommands: false` ensures connection errors surface immediately rather than queuing
- `MONGO_MAX_IDLE_TIME_MS=45000` prevents stale connections after Lambda freeze/thaw cycles
- Connection errors are logged as structured JSON (`CONSOLE_JSON=true`) and surfaced in CloudWatch

### ElastiCache Connection Errors

- `ioredis` reconnect strategy: exponential backoff with max 3 retries
- If Redis is unavailable, LibreChat falls back to in-memory stores for non-critical caches (rate limiters use `memorystore`)
- Session failures result in 401 responses, prompting re-authentication

### MeiliSearch Unavailability

- When `EnableMeiliSearch=false`, `SEARCH=false` disables the search feature entirely
- When enabled but ECS task is unhealthy, the API logs a warning and disables search gracefully (existing behavior in `api/server/index.js` uncaughtException handler for MeiliSearch errors)

### API Gateway / Lambda Timeouts

- Lambda timeout: 30 seconds
- API Gateway integration timeout: 29 seconds (must be < Lambda timeout)
- Streaming responses via `InvokeWithResponseStream` bypass the 29s API GW timeout for AI token streams

### Deployment Failures

- CloudFormation rollback on failure: enabled
- Failed deployments trigger SNS notification via CloudWatch alarm
- Database schema migrations are idempotent (safe to re-run)

---

## Observability

### CloudWatch Log Groups

| Resource | Log Group | Retention |
|---|---|---|
| API Lambda | `/aws/lambda/librechat-api-{env}` | 30 days |
| API Gateway | `/aws/apigateway/librechat-{env}` | 30 days |
| ECS MeiliSearch | `/ecs/librechat-meili-{env}` | 14 days |

### CloudWatch Dashboard

Widgets:
- Lambda: Invocations, Errors, Duration (p50/p95/p99), Throttles, ConcurrentExecutions
- API Gateway: 4xx/5xx count, Latency (p50/p99), IntegrationLatency
- DocumentDB: DatabaseConnections, ReadLatency, WriteLatency
- ElastiCache: CacheHits, CacheMisses, CurrConnections, EngineCPUUtilization

### Alarms

| Alarm | Condition | Action |
|---|---|---|
| `LambdaErrorRate` | Errors/Invocations > 5% over 5 min | SNS → email |
| `LambdaThrottles` | Throttles > 10 over 1 min | SNS → email |
| `LambdaDuration` | p99 > 25s over 5 min | SNS → email |
| `DocDBConnections` | DatabaseConnections > 80% of max | SNS → email |

### X-Ray Tracing

X-Ray active tracing is enabled on both the Lambda function and API Gateway. The AWS SDK calls (Secrets Manager, S3, SES) are automatically instrumented. DocumentDB and ElastiCache calls appear as subsegments via the X-Ray SDK.

---

## Testing Strategy

This feature is primarily IaC and infrastructure configuration. Property-based testing is **not applicable** here — the deployment system is declarative configuration (SAM/CloudFormation templates), not a function with input/output behavior amenable to universal quantification.

The appropriate testing strategy is:

### Unit Tests (existing)
- The LibreChat application's existing Jest test suite (`npm test`) runs in CI before deployment
- No new unit tests are required for the IaC itself

### Infrastructure Validation
- `sam validate` — validates SAM template syntax and schema before deployment
- `cfn-lint` — additional CloudFormation linting in CI
- `cfn-guard` — policy/compliance checks (e.g., encryption at rest, no public S3 buckets)

### Smoke Tests (post-deploy)
- `GET /health` → 200 OK (Lambda + API Gateway wiring)
- `GET /` via CloudFront → 200 with `index.html` content
- `GET /api/config` → 200 with valid JSON (secrets loaded, DB connected)
- CloudFront HTTPS redirect: `HTTP GET /` → 301 to `https://`

### Integration Tests (per environment)
- DocumentDB connectivity: verified by `/api/config` returning a valid response (requires DB connection)
- ElastiCache connectivity: verified by session creation on login
- S3 upload: verified by uploading a test file and checking pre-signed URL access
- SES: verified in sandbox mode against a verified test recipient address

### Deployment Validation
- CloudFormation change set review before `prod` deployments (manual approval gate in GitHub Actions)
- Automated rollback tested in `staging` by intentionally deploying a broken Lambda and verifying rollback

---

## Correctness Properties

This feature is an IaC deployment system. The core deliverables are CloudFormation/SAM templates, shell scripts, and CI/CD pipeline configuration — all declarative or procedural infrastructure code rather than pure functions with testable input/output behavior.

Property-based testing does not apply to this feature. The acceptance criteria fall into these non-PBT categories:

- **SMOKE**: Infrastructure configuration checks (encryption enabled, public access blocked, TLS enforced) — verified once per deployment
- **INTEGRATION**: End-to-end wiring checks (Lambda connects to DocumentDB, CloudFront serves index.html) — verified with 1-3 representative examples post-deploy
- **EXAMPLE**: Specific behavioral checks (SPA fallback returns index.html, HTTPS redirect works) — verified with concrete example-based tests

The Testing Strategy section above covers all acceptance criteria with the appropriate test types.
