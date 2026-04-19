# Implementation Plan: AWS Serverless Deployment for LibreChat

## Overview

Implement the full AWS SAM-based infrastructure for LibreChat across nested stacks, CI/CD pipelines, observability, and deployment scripts. Tasks are ordered so each builds on the previous, ending with full integration.

## Tasks

- [x] 1. Scaffold IaC directory structure and root SAM template
  - Create `infra/` directory with `template.yaml`, `samconfig.toml`, and `nested/`, `mcp/`, `scripts/`, `layers/` subdirectories
  - Write root `template.yaml` with all SAM `Parameters` (`Environment`, `MultiAZ`, `EnableMeiliSearch`, `CustomDomain`, `HostedZoneId`, `LambdaMemorySize`, `DocumentDBMode`, `DocumentDBInstanceClass`, `ElastiCacheNodeType`, `CIPlatform`, `CodeStarConnectionArn`, `RepositoryId`, `BranchName`)
  - Add `AWS::CloudFormation::Stack` resources in root template for each nested stack, passing shared parameters and cross-stack outputs as inputs
  - Write `samconfig.toml` with `[dev.deploy.parameters]` and `[prod.deploy.parameters]` sections
  - Add `Outputs` section to root template (`CloudFrontURL`, `APIGatewayURL`, `FrontendBucketName`, `UploadsBucketName`, `DocumentDBEndpoint`, `ElastiCacheEndpoint`)
  - _Requirements: 12.1, 12.2, 12.4_

- [x] 2. Implement VPC and networking (`infra/nested/vpc.yaml`)
  - [x] 2.1 Create VPC resource (`10.0.0.0/16`) with Internet Gateway and VPC-IGW attachment
    - _Requirements: 7.1, 7.2_
  - [x] 2.2 Add `MultiAZ` condition and subnet resources
    - Condition: `IsMultiAZ: !Equals [!Ref MultiAZ, "true"]`
    - Public subnets: `10.0.0.0/24` (AZ1), `10.0.1.0/24` (AZ2, conditional on `IsMultiAZ`)
    - Private subnets: `10.0.2.0/24` (AZ1), `10.0.3.0/24` (AZ2, conditional on `IsMultiAZ`)
    - _Requirements: 7.1, 7.2_
  - [x] 2.3 Add NAT Gateways, Elastic IPs, and route tables
    - NAT Gateway in AZ1 always; NAT Gateway in AZ2 only when `IsMultiAZ`
    - Private route tables routing `0.0.0.0/0` to respective NAT Gateway
    - _Requirements: 7.2_
  - [x] 2.4 Define all five security groups (`sg-lambda`, `sg-docdb`, `sg-redis`, `sg-meili`, `sg-mcp`) with exact inbound/outbound rules from the design
    - `sg-lambda`: egress 443 to `0.0.0.0/0`, 27017 to `sg-docdb`, 6379 to `sg-redis`, 7700 to `sg-meili`, 443 to `sg-mcp`
    - `sg-docdb`: ingress 27017 from `sg-lambda` only
    - `sg-redis`: ingress 6379 from `sg-lambda` only
    - `sg-meili`: ingress 7700 from `sg-lambda` only
    - `sg-mcp`: ingress 443 from `sg-lambda`; egress 443 to `0.0.0.0/0`, 27017 to `sg-docdb`, 6379 to `sg-redis`
    - _Requirements: 7.3, 7.4, 7.5_
  - [x] 2.5 Export VPC ID, subnet IDs, and security group IDs as stack outputs for consumption by nested stacks
    - _Requirements: 7.1_

- [x] 3. Implement DocumentDB stack (`infra/nested/database.yaml`)
  - [x] 3.1 Create DocumentDB subnet group spanning private subnets (both AZs when `IsMultiAZ`, single AZ otherwise)
    - _Requirements: 3.2_
  - [x] 3.2 Create DocumentDB cluster parameter group with `tls: enabled`
    - _Requirements: 3.5_
  - [x] 3.3 Add `DocumentDBMode` condition (`IsProvisioned: !Equals [!Ref DocumentDBMode, "provisioned"]`) and write the `AWS::DocDB::DBCluster` resource
    - Provisioned: standard cluster with `DBInstanceClass` from parameter, `StorageEncrypted: true`, KMS CMK, backup retention 7 days
    - Serverless: add `ServerlessV2ScalingConfiguration` (MinCapacity 0.5, MaxCapacity 16), `StorageEncrypted: true`
    - _Requirements: 3.1, 3.4, 3.5_
  - [x] 3.4 Add `AWS::DocDB::DBInstance` resources
    - Provisioned + `IsMultiAZ`: writer instance in AZ1 + reader instance in AZ2
    - Provisioned + single-AZ: writer instance only
    - Serverless: single instance with `DBInstanceClass: db.serverless`
    - _Requirements: 3.1_
  - [x] 3.5 Create the DocumentDB CA bundle Lambda layer (`infra/layers/docdb-ca/`)
    - Download `rds-combined-ca-bundle.pem` and package as a Lambda layer ZIP
    - Define `AWS::Serverless::LayerVersion` resource in the database stack (or root template)
    - _Requirements: 3.3_

- [x] 4. Implement ElastiCache stack (`infra/nested/cache.yaml`)
  - [x] 4.1 Create ElastiCache subnet group using private subnets
    - _Requirements: 4.1_
  - [x] 4.2 Write `AWS::ElastiCache::ReplicationGroup` resource
    - Engine: Valkey 7.2 (or Redis OSS 7.x), cluster mode disabled
    - `TransitEncryptionEnabled: true`, `AtRestEncryptionEnabled: true`
    - Auth token sourced from Secrets Manager (reference via dynamic SSM/SM parameter)
    - `IsMultiAZ=true`: `NumCacheClusters: 2`, `AutomaticFailoverEnabled: true`, `MultiAZEnabled: true`
    - `IsMultiAZ=false`: `NumCacheClusters: 1`, `AutomaticFailoverEnabled: false`
    - Node type from `ElastiCacheNodeType` parameter
    - _Requirements: 4.1, 4.4, 4.5_
  - [x] 4.3 Export primary endpoint as stack output
    - _Requirements: 4.3_

- [x] 5. Implement S3 storage stacks (`infra/nested/storage.yaml` and `infra/nested/frontend.yaml`)
  - [x] 5.1 Create uploads S3 bucket in `storage.yaml`
    - Name: `librechat-uploads-${AWS::AccountId}-${Environment}`
    - `BlockPublicAcls: true`, `BlockPublicPolicy: true`, `IgnorePublicAcls: true`, `RestrictPublicBuckets: true`
    - Versioning enabled, SSE-S3 encryption, lifecycle rule transitioning to Intelligent-Tiering after 30 days
    - CORS configuration allowing PUT/GET from CloudFront domain
    - _Requirements: 5.1, 5.2, 5.5_
  - [x] 5.2 Create frontend assets S3 bucket in `frontend.yaml`
    - Name: `librechat-frontend-${AWS::AccountId}-${Environment}`
    - Block all public access, no static website hosting (served via CloudFront OAC only)
    - _Requirements: 1.1, 1.6_

- [x] 6. Implement Secrets Manager and SSM Parameter Store stack (`infra/nested/secrets.yaml`)
  - [x] 6.1 Create `AWS::SecretsManager::Secret` resource `librechat/{env}/secrets` with placeholder JSON structure for all required keys (`MONGO_URI`, `REDIS_URI`, `JWT_SECRET`, `JWT_REFRESH_SECRET`, `CREDS_KEY`, `CREDS_IV`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `MEILI_MASTER_KEY`, `EMAIL_FROM`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`)
    - _Requirements: 6.1_
  - [x] 6.2 Create `AWS::SSM::Parameter` resources for all non-secret config values under `/librechat/{env}/config/` (`DOMAIN_CLIENT`, `DOMAIN_SERVER`, `MEILI_HOST`, `SEARCH`, `librechat_yaml`, `CONSOLE_JSON`, `TRUST_PROXY`, `UPLOADS_BUCKET`, `FRONTEND_BUCKET`)
    - _Requirements: 6.4_
  - [x] 6.3 Export secret ARN and parameter ARNs as stack outputs for use by Lambda IAM policy
    - _Requirements: 6.3_

- [x] 7. Implement Lambda API function stack (`infra/nested/api-lambda.yaml`)
  - [x] 7.1 Write `AWS::Serverless::Function` resource for the LibreChat API
    - Runtime: `nodejs20.x`, architecture `x86_64`
    - Memory from `LambdaMemorySize` parameter, timeout 30s
    - Handler: `run.sh` (LWA bootstrap), `CodeUri` pointing to repo root
    - VPC config: private subnets + `sg-lambda`
    - Environment variables: `AWS_LAMBDA_EXEC_WRAPPER=/opt/bootstrap`, `PORT=3080`, `READINESS_CHECK_PATH=/health`, `SECRET_ARN` (from secrets stack output), `CONSOLE_JSON=true`, `TRUST_PROXY=1`
    - Layers: LWA layer ARN + DocumentDB CA layer ARN
    - `Tracing: Active`
    - _Requirements: 2.1, 2.2, 2.5, 2.6, 13.6_
  - [x] 7.2 Add secret-loading bootstrap code
    - Create `infra/lambda-bootstrap/init-secrets.js` that calls `SecretsManager.getSecretValue` at module init and merges into `process.env`, with fail-fast error handling (`process.exit(1)` on failure)
    - Reference this file as the Lambda entry point wrapper (or add to `NODE_OPTIONS` pre-require)
    - _Requirements: 2.6, 6.2_
  - [x] 7.3 Write least-privilege IAM role and policies for the Lambda function
    - `secretsmanager:GetSecretValue` scoped to the secret ARN
    - `ssm:GetParameter` and `ssm:GetParametersByPath` scoped to `/librechat/{env}/config/*`
    - `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` scoped to uploads bucket ARN + `/*`
    - `ses:SendEmail`, `ses:SendRawEmail` scoped to verified SES identity ARN
    - `xray:PutTraceSegments`, `xray:PutTelemetryRecords`
    - VPC ENI permissions (`ec2:CreateNetworkInterface`, `ec2:DescribeNetworkInterfaces`, `ec2:DeleteNetworkInterface`)
    - _Requirements: 5.3, 6.3, 7.6, 9.2_
  - [x] 7.4 Create API Gateway HTTP API (v2) resource and Lambda integration
    - `AWS::ApiGatewayV2::Api` with `ProtocolType: HTTP`
    - `AWS::ApiGatewayV2::Integration` with `IntegrationType: AWS_PROXY`, `PayloadFormatVersion: "2.0"`
    - `AWS::ApiGatewayV2::Route` for `$default`
    - `AWS::ApiGatewayV2::Stage` with access logging to CloudWatch log group
    - Binary media types: `multipart/form-data`, `application/octet-stream`
    - Integration timeout: 29000ms
    - _Requirements: 2.3, 2.7, 13.4_
  - [x] 7.5 Enable Lambda response streaming for AI token output
    - Add `FunctionUrlConfig` with `AuthType: NONE` (CloudFront handles auth) and `InvokeMode: RESPONSE_STREAM`
    - _Requirements: 2.8_

- [x] 8. Checkpoint — validate SAM templates so far
  - Run `sam validate` on root template and all nested stacks created to this point
  - Run `cfn-lint` on all YAML files in `infra/`
  - Fix any schema or lint errors before proceeding
  - _Requirements: 12.1_

- [x] 9. Implement CloudFront, WAF, ACM, and Route 53 stack (`infra/nested/frontend.yaml`)
  - [x] 9.1 Create WAF WebACL (`AWS::WAFv2::WebACL`) in `us-east-1` scope `CLOUDFRONT`
    - Attach `AWSManagedRulesCommonRuleSet` managed rule group
    - _Requirements: 7.7_
  - [x] 9.2 Create CloudFront Origin Access Control (`AWS::CloudFront::OriginAccessControl`) for the frontend S3 bucket
    - _Requirements: 1.6_
  - [x] 9.3 Write `AWS::CloudFront::Distribution` resource
    - Origins: S3 frontend bucket (OAC) + API Gateway HTTP API
    - Cache behaviors: `/api/*` → API GW (TTL=0, no cache); `/*.js`, `/*.css`, `/*.woff2` → S3 (TTL=86400); default `/*` → S3 (TTL=0)
    - `DefaultRootObject: index.html`
    - Custom error responses: 403 → `/index.html` (200), 404 → `/index.html` (200)
    - `ViewerProtocolPolicy: redirect-to-https`, `MinimumProtocolVersion: TLSv1.2_2021`
    - `WebACLId` referencing the WAF WebACL
    - `Aliases` and `ViewerCertificate` conditional on `CustomDomain` parameter being non-empty
    - _Requirements: 1.2, 1.3, 1.4, 1.5, 1.7, 7.7, 8.2, 8.4_
  - [x] 9.4 Add S3 bucket policy granting CloudFront OAC read access to the frontend bucket
    - _Requirements: 1.6_
  - [x] 9.5 Add conditional ACM certificate (`AWS::CertificateManager::Certificate`) with DNS validation
    - Condition: `HasCustomDomain: !Not [!Equals [!Ref CustomDomain, ""]]`
    - `DomainValidationOptions` using `HostedZoneId` parameter
    - _Requirements: 8.1, 8.5_
  - [x] 9.6 Add conditional Route 53 A alias record pointing custom domain to CloudFront distribution
    - _Requirements: 8.3_

- [x] 10. Implement SES stack (`infra/nested/ses.yaml`)
  - Create `AWS::SES::EmailIdentity` resource for the sender domain
  - Add `AWS::Route53::RecordSetGroup` for DKIM CNAME records produced by the SES identity (using `DkimDNSTokenName` / `DkimDNSTokenValue` attributes)
  - Export the SES identity ARN for use in the Lambda IAM policy
  - _Requirements: 9.1, 9.3_

- [x] 11. Implement MeiliSearch optional stack (`infra/nested/meilisearch.yaml`)
  - [x] 11.1 Add `EnableMeiliSearch` condition to the nested stack and guard all resources with it
    - _Requirements: 10.1_
  - [x] 11.2 Create EFS file system and mount targets in private subnets for MeiliSearch index persistence
    - `AWS::EFS::FileSystem` with encryption enabled
    - `AWS::EFS::MountTarget` per private subnet
    - _Requirements: 10.3_
  - [x] 11.3 Create ECS Fargate cluster, task definition, and service for MeiliSearch
    - Task definition: `getmeili/meilisearch:latest`, 0.5 vCPU, 1 GB memory, EFS volume mounted at `/meili_data`
    - Service: `LaunchType: FARGATE`, private subnets, `sg-meili`
    - `MEILI_MASTER_KEY` sourced from Secrets Manager via ECS secrets
    - CloudWatch log group `/ecs/librechat-meili-{env}` with 14-day retention
    - _Requirements: 10.2, 10.4, 10.5_
  - [x] 11.4 Create AWS Cloud Map namespace and service for internal DNS (`meili.librechat.local:7700`)
    - _Requirements: 10.2_

- [x] 12. Implement MCP Lambda functions stack (`infra/mcp/template.yaml`)
  - [x] 12.1 Write a reusable `AWS::Serverless::Function` pattern for MCP Lambda functions
    - Runtime: `nodejs20.x`, VPC private subnets, `sg-mcp`, timeout 60s
    - `FunctionUrlConfig` with `AuthType: AWS_IAM`
    - IAM permissions: `secretsmanager:GetSecretValue` (scoped), `elasticache:Connect` (scoped), VPC ENI permissions
    - _Requirements: 11.1, 11.2, 11.3_
  - [x] 12.2 Add a placeholder MCP function (`HelloWorldMCP`) as a concrete example demonstrating the pattern
    - Stateless handler that reads/writes state to ElastiCache
    - _Requirements: 11.4, 11.5_
  - [x] 12.3 Write `infra/scripts/add-mcp-server.md` documenting the steps to add a new MCP server (add SAM resource, update `librechat.yaml` in SSM Parameter Store, deploy)
    - _Requirements: 11.6_

- [x] 13. Implement observability stack (`infra/nested/observability.yaml`)
  - [x] 13.1 Create CloudWatch Log Groups for Lambda (`/aws/lambda/librechat-api-{env}`, 30-day retention) and API Gateway (`/aws/apigateway/librechat-{env}`, 30-day retention)
    - _Requirements: 13.2, 13.4_
  - [x] 13.2 Create CloudWatch Dashboard with widgets for Lambda (Invocations, Errors, Duration p50/p95/p99, Throttles, ConcurrentExecutions), API Gateway (4xx/5xx, Latency p50/p99, IntegrationLatency), DocumentDB (DatabaseConnections, ReadLatency, WriteLatency), and ElastiCache (CacheHits, CacheMisses, CurrConnections, EngineCPUUtilization)
    - _Requirements: 13.3_
  - [x] 13.3 Create SNS topic for alerts and CloudWatch Alarms
    - `LambdaErrorRate`: Errors/Invocations > 5% over 5 min → SNS
    - `LambdaThrottles`: Throttles > 10 over 1 min → SNS
    - `LambdaDuration`: p99 > 25s over 5 min → SNS
    - `DocDBConnections`: DatabaseConnections > 80% of max → SNS
    - _Requirements: 13.5_
  - [x] 13.4 Enable X-Ray active tracing on Lambda function and API Gateway stage (set `TracingConfig: Active` and `DefaultRouteSettings.DetailedMetricsEnabled: true`)
    - _Requirements: 13.6_

- [x] 14. Checkpoint — full SAM validate and cfn-lint pass
  - Run `sam validate` on root template and all nested stacks
  - Run `cfn-lint` across all `infra/**/*.yaml` files
  - Ensure all cross-stack parameter references resolve correctly
  - _Requirements: 12.1_

- [x] 15. Implement build and deployment scripts (`infra/scripts/`)
  - [x] 15.1 Write `infra/scripts/build-frontend.sh`
    - Run `npm ci` and `npm run frontend` from repo root
    - Sync `client/dist/` to the frontend S3 bucket using `aws s3 sync --delete`
    - _Requirements: 1.1_
  - [x] 15.2 Write `infra/scripts/invalidate-cf.sh`
    - Accept environment name as argument, look up CloudFront distribution ID from CloudFormation stack output `CloudFrontURL`
    - Run `aws cloudfront create-invalidation --paths "/*"` (or `"/index.html"` for targeted invalidation)
    - _Requirements: 1.7_
  - [x] 15.3 Write `infra/scripts/seed-docdb.sh`
    - Connect to DocumentDB via the `MONGO_URI` from Secrets Manager (using `mongosh` or a Node.js script)
    - Create the `LibreChat` database and required indexes idempotently
    - _Requirements: 3.6_
  - [x] 15.4 Write `infra/scripts/smoke-test.sh`
    - `GET /health` → assert HTTP 200
    - `GET /` via CloudFront URL → assert HTTP 200 and `index.html` content
    - `GET /api/config` → assert HTTP 200 and valid JSON body
    - HTTP `GET /` → assert redirect to `https://` (301/302)
    - Exit non-zero on any failure
    - _Requirements: 12.3_

- [x] 16. Implement CI/CD pipeline
  - [x] 16.1 Write GitHub Actions workflow (`.github/workflows/deploy.yml`)
    - Triggers: push to `main`, `workflow_dispatch` with `environment` input (`dev`/`staging`/`prod`)
    - Steps: checkout → configure AWS credentials (OIDC, `role-to-assume`) → `npm ci` → `npm test --workspace=api` → `npm run frontend` → `sam build` → `sam deploy --no-confirm-changeset` → `bash infra/scripts/build-frontend.sh` → `bash infra/scripts/invalidate-cf.sh` → `bash infra/scripts/smoke-test.sh`
    - Use `environment:` context for per-environment secrets (`AWS_DEPLOY_ROLE_ARN`)
    - _Requirements: 12.3_
  - [x] 16.2 Create the OIDC IAM role CloudFormation template (or inline in root SAM template) for GitHub Actions
    - `AWS::IAM::OIDCProvider` for `token.actions.githubusercontent.com`
    - Deploy role with scoped permissions: `cloudformation:*` (scoped to `librechat-*` stacks), `s3:*` (scoped to deployment buckets), `lambda:*` (scoped to `librechat-*` functions), `iam:PassRole`
    - _Requirements: 7.6, 12.3_
  - [x] 16.3 Add conditional CodePipeline stack (`infra/nested/pipeline.yaml`) gated on `CIPlatform=codepipeline`
    - `AWS::CodePipeline::Pipeline` with Source (CodeStar Connections), Build (CodeBuild), Deploy (CloudFormation changeset), Post-Deploy (CodeBuild) stages
    - CodeBuild buildspec for Build stage: `npm ci`, `npm test`, `npm run frontend`, `sam build`
    - CodeBuild buildspec for Post-Deploy stage: `build-frontend.sh`, `invalidate-cf.sh`, `smoke-test.sh`
    - Pipeline artifacts bucket: `librechat-pipeline-${AWS::AccountId}-${Environment}` with versioning, SSE-S3, 30-day lifecycle
    - Least-privilege IAM role for CodePipeline (scoped permissions per design)
    - Optional manual approval action before Deploy stage when `Environment=prod`
    - _Requirements: 12.3, 12.5_

- [x] 17. Final checkpoint — end-to-end wiring verification
  - Ensure all nested stack outputs are correctly referenced as inputs in the root `template.yaml`
  - Verify `samconfig.toml` has valid entries for `dev`, `staging`, and `prod` environments
  - Run `sam validate` one final time on the complete root template
  - Run `cfn-lint` and `cfn-guard` (encryption at rest, no public S3 buckets) across all templates
  - Ensure all scripts are executable (`chmod +x infra/scripts/*.sh`)
  - _Requirements: 12.1, 12.2, 12.5_

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP — none in this plan since PBT does not apply to IaC
- Each task references specific requirements for traceability
- Checkpoints (tasks 8, 14, 17) ensure incremental validation with `sam validate` and `cfn-lint`
- The `MultiAZ` parameter controls HA vs. cost trade-offs across VPC, DocumentDB, and ElastiCache — all three stacks must handle both conditions consistently
- The `DocumentDBMode` condition (provisioned vs. serverless) is independent of `MultiAZ`; serverless mode ignores `MultiAZ`
- MeiliSearch (task 11) and CodePipeline (task 16.3) are conditional and can be skipped for a minimal deployment
