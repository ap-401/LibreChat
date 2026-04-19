# Requirements Document

## Introduction

This document defines the requirements for deploying the LibreChat application to AWS using serverless and native AWS managed services. LibreChat is a full-stack AI chat platform consisting of a Node.js/Express API backend, a React frontend, MongoDB-backed persistence, Redis-based caching and session management, S3-compatible file storage, MCP (Model Context Protocol) server support, and integrations with multiple AI providers (OpenAI, Anthropic, AWS Bedrock, Google, etc.).

The deployment must avoid AWS Amplify and instead leverage AWS-native serverless primitives: AWS Lambda (via Lambda Web Adapter) for the API, Amazon CloudFront + S3 for the frontend, Amazon DocumentDB or MongoDB Atlas for the database, Amazon ElastiCache (Valkey/Redis) for caching, Amazon S3 for file storage, AWS Secrets Manager for secrets, and AWS SAM or CDK for infrastructure-as-code.

---

## Glossary

- **API**: The LibreChat Node.js/Express backend located in the `/api` directory.
- **Frontend**: The LibreChat React application located in the `/client` directory.
- **Deployment_System**: The AWS infrastructure and IaC tooling responsible for provisioning and managing all AWS resources.
- **Lambda_Function**: The AWS Lambda function running the LibreChat API via the Lambda Web Adapter.
- **API_Gateway**: Amazon API Gateway (HTTP API) acting as the public HTTP entry point for the API.
- **CloudFront**: Amazon CloudFront CDN distribution serving the React frontend assets and proxying API requests.
- **S3_Bucket**: Amazon S3 bucket used for static frontend asset hosting and user-uploaded file storage.
- **DocumentDB**: Amazon DocumentDB (MongoDB-compatible) cluster used as the primary database.
- **ElastiCache**: Amazon ElastiCache for Redis (or Valkey) cluster used for session storage, caching, and resumable streams.
- **Secrets_Manager**: AWS Secrets Manager used to store all application secrets and environment variables.
- **VPC**: Amazon Virtual Private Cloud providing network isolation for ElastiCache, DocumentDB, and Lambda.
- **IAM_Role**: AWS Identity and Access Management role granting least-privilege permissions to Lambda and other services.
- **SAM_Template**: AWS Serverless Application Model template defining all infrastructure resources.
- **MCP_Server**: Model Context Protocol server processes that LibreChat connects to for tool integrations.
- **ECR**: Amazon Elastic Container Registry, used if the API is packaged as a container image for Lambda.
- **SES**: Amazon Simple Email Service used for transactional email (password reset, invitations).
- **WAF**: AWS Web Application Firewall attached to CloudFront for request filtering and rate limiting.
- **Parameter_Store**: AWS Systems Manager Parameter Store, used for non-secret configuration values.
- **Meili**: MeiliSearch, the full-text search engine used by LibreChat for conversation search. An optional, opt-in component.
- **MCP_Lambda**: An AWS Lambda function deployed within the VPC to host a single stateless MCP server.
- **RAG_API**: The optional Python-based Retrieval-Augmented Generation API service.

---

## Requirements

### Requirement 1: Frontend Static Asset Hosting

**User Story:** As a LibreChat operator, I want the React frontend served from a globally distributed CDN, so that users experience fast page loads regardless of geographic location.

#### Acceptance Criteria

1. THE Deployment_System SHALL build the React frontend and upload the resulting static assets to a dedicated S3_Bucket configured for static website hosting.
2. THE Deployment_System SHALL provision a CloudFront distribution with the S3_Bucket as its origin for all frontend assets.
3. WHEN a user requests the root URL, THE CloudFront SHALL serve `index.html` as the default root object.
4. WHEN a user requests a path that does not match a static asset, THE CloudFront SHALL return `index.html` to support client-side routing (SPA fallback).
5. THE CloudFront SHALL enforce HTTPS-only access and redirect all HTTP requests to HTTPS.
6. THE S3_Bucket hosting frontend assets SHALL block all public access directly and serve content exclusively through CloudFront using an Origin Access Control (OAC) policy.
7. THE CloudFront SHALL set cache headers with a minimum TTL of 86400 seconds for versioned static assets (JS, CSS, fonts) and 0 seconds for `index.html`.

---

### Requirement 2: API Backend Deployment on Lambda

**User Story:** As a LibreChat operator, I want the Node.js/Express API deployed as an AWS Lambda function, so that I pay only for actual compute usage and avoid managing servers.

#### Acceptance Criteria

1. THE Deployment_System SHALL package the LibreChat API using the AWS Lambda Web Adapter so the existing Express application runs without code changes.
2. THE Lambda_Function SHALL be configured with a minimum memory of 1024 MB and a timeout of 30 seconds to accommodate AI streaming responses.
3. THE API_Gateway SHALL be provisioned as an HTTP API (v2) and integrated with the Lambda_Function using a Lambda proxy integration.
4. THE CloudFront SHALL route all requests matching the `/api/*` path pattern to the API_Gateway origin.
5. WHEN the Lambda_Function requires access to ElastiCache or DocumentDB, THE Lambda_Function SHALL be deployed inside the VPC with appropriate security group rules.
6. THE Lambda_Function SHALL retrieve all secrets and configuration values from Secrets_Manager at cold-start initialization, not at build time.
7. THE Deployment_System SHALL configure Lambda function URLs or API_Gateway with binary media type support to handle file uploads and multipart form data.
8. WHERE response streaming is required for AI token output, THE Lambda_Function SHALL use Lambda response streaming (InvokeWithResponseStream) to deliver tokens to the client progressively.

---

### Requirement 3: Database Provisioning

**User Story:** As a LibreChat operator, I want a managed, MongoDB-compatible database, so that I do not need to operate database servers manually.

#### Acceptance Criteria

1. THE Deployment_System SHALL provision an Amazon DocumentDB cluster with at least one writer instance and one reader instance for high availability.
2. THE DocumentDB cluster SHALL be deployed inside the VPC and SHALL NOT be publicly accessible.
3. THE Lambda_Function SHALL connect to DocumentDB using a connection string stored in Secrets_Manager.
4. THE Deployment_System SHALL enable automated backups on the DocumentDB cluster with a retention period of at least 7 days.
5. THE DocumentDB cluster SHALL have encryption at rest enabled using an AWS KMS key.
6. WHEN the DocumentDB cluster is provisioned, THE Deployment_System SHALL create the `LibreChat` database and required indexes as part of the deployment pipeline.
7. IF the operator prefers MongoDB Atlas over DocumentDB, THEN THE Deployment_System SHALL support an alternative configuration that stores the MongoDB Atlas connection string in Secrets_Manager and skips DocumentDB provisioning.

---

### Requirement 4: Caching and Session Storage

**User Story:** As a LibreChat operator, I want a managed Redis-compatible cache, so that user sessions, rate-limit counters, and resumable AI streams are persisted across Lambda invocations.

#### Acceptance Criteria

1. THE Deployment_System SHALL provision an Amazon ElastiCache cluster (Valkey or Redis OSS engine) inside the VPC.
2. THE ElastiCache cluster SHALL be accessible only from the Lambda_Function security group and SHALL NOT be publicly accessible.
3. THE Lambda_Function SHALL connect to ElastiCache using the `REDIS_URI` environment variable sourced from Secrets_Manager.
4. THE Deployment_System SHALL enable in-transit encryption (TLS) on the ElastiCache cluster.
5. THE Deployment_System SHALL enable at-rest encryption on the ElastiCache cluster.
6. WHEN the `USE_REDIS` environment variable is set to `true`, THE API SHALL use ElastiCache for all session storage, rate-limit state, and stream resumption.

---

### Requirement 5: File Storage

**User Story:** As a LibreChat operator, I want user-uploaded files stored in Amazon S3, so that files persist independently of Lambda function lifecycle and are accessible across invocations.

#### Acceptance Criteria

1. THE Deployment_System SHALL provision a dedicated S3_Bucket for user-uploaded files, separate from the frontend asset bucket.
2. THE S3_Bucket for uploads SHALL block all public access and serve files exclusively through pre-signed URLs generated by the Lambda_Function.
3. THE Lambda_Function SHALL have an IAM_Role with `s3:PutObject`, `s3:GetObject`, and `s3:DeleteObject` permissions scoped to the uploads S3_Bucket.
4. THE Deployment_System SHALL configure the `AWS_BUCKET_NAME`, `AWS_REGION`, and related S3 environment variables in the Lambda_Function sourced from Secrets_Manager.
5. THE S3_Bucket for uploads SHALL have versioning enabled and a lifecycle policy that transitions objects to S3 Intelligent-Tiering after 30 days.
6. WHEN a user uploads a file, THE Lambda_Function SHALL store the file in the uploads S3_Bucket and return a pre-signed URL valid for no more than 3600 seconds.

---

### Requirement 6: Secrets and Configuration Management

**User Story:** As a LibreChat operator, I want all secrets and sensitive configuration values stored in AWS Secrets Manager, so that credentials are never embedded in code or container images.

#### Acceptance Criteria

1. THE Deployment_System SHALL store all LibreChat secrets (JWT secrets, API keys, database credentials, OAuth client secrets) in Secrets_Manager as a single versioned JSON secret per environment.
2. THE Lambda_Function SHALL retrieve secrets from Secrets_Manager using the AWS Lambda Powertools Parameters utility or the AWS SDK at cold-start, and SHALL cache the values for the duration of the Lambda execution environment lifetime.
3. THE IAM_Role assigned to the Lambda_Function SHALL include `secretsmanager:GetSecretValue` permission scoped to only the secrets required by the application.
4. THE Deployment_System SHALL store non-secret configuration values (e.g., `DOMAIN_CLIENT`, `MEILI_HOST`, feature flags) in Parameter_Store as SecureString parameters.
5. WHEN a secret is rotated in Secrets_Manager, THE Lambda_Function SHALL retrieve the updated secret on the next cold start without requiring a redeployment.

---

### Requirement 7: Networking and Security

**User Story:** As a LibreChat operator, I want all backend resources isolated in a private VPC with least-privilege IAM policies, so that the attack surface is minimized.

#### Acceptance Criteria

1. THE Deployment_System SHALL provision a VPC with at least two private subnets across two Availability Zones for Lambda, ElastiCache, and DocumentDB.
2. THE Deployment_System SHALL provision at least two public subnets for NAT Gateways to allow Lambda outbound internet access to external AI provider APIs.
3. THE Lambda_Function SHALL be assigned a security group that permits outbound HTTPS (port 443) to the internet and inbound connections only from API_Gateway.
4. THE DocumentDB cluster SHALL be assigned a security group that permits inbound connections only on port 27017 from the Lambda_Function security group.
5. THE ElastiCache cluster SHALL be assigned a security group that permits inbound connections only on port 6379 from the Lambda_Function security group.
6. THE IAM_Role for the Lambda_Function SHALL follow least-privilege principles and SHALL NOT include wildcard resource permissions (`*`) for any AWS service action.
7. THE Deployment_System SHALL attach a WAF WebACL to the CloudFront distribution with AWS managed rule groups for common web exploits (AWSManagedRulesCommonRuleSet).

---

### Requirement 8: Custom Domain and TLS

**User Story:** As a LibreChat operator, I want the application accessible via a custom domain with a valid TLS certificate, so that users access the application through a branded, secure URL.

#### Acceptance Criteria

1. THE Deployment_System SHALL provision an ACM certificate in the `us-east-1` region for the custom domain and associate it with the CloudFront distribution.
2. THE CloudFront distribution SHALL be configured with the custom domain as an alternate domain name (CNAME).
3. THE Deployment_System SHALL create a Route 53 A record (alias) pointing the custom domain to the CloudFront distribution.
4. THE CloudFront distribution SHALL enforce a minimum TLS policy of TLSv1.2_2021.
5. WHEN the ACM certificate is requested, THE Deployment_System SHALL use DNS validation via Route 53 to automatically validate domain ownership.

---

### Requirement 9: Email Service

**User Story:** As a LibreChat operator, I want transactional emails (password reset, user invitations) sent via Amazon SES, so that I do not depend on third-party email providers.

#### Acceptance Criteria

1. THE Deployment_System SHALL configure the LibreChat API to use Amazon SES as the email transport by setting `EMAIL_SERVICE` to `SES` and providing the `AWS_REGION` in the Lambda_Function environment.
2. THE IAM_Role for the Lambda_Function SHALL include `ses:SendEmail` and `ses:SendRawEmail` permissions scoped to the verified SES identity.
3. THE Deployment_System SHALL verify the sender email domain in SES as part of the deployment pipeline.
4. WHEN SES is in sandbox mode, THE Deployment_System documentation SHALL note that only verified recipient addresses can receive email until SES production access is requested.

---

### Requirement 10: Search Service (MeiliSearch) — Optional

**User Story:** As a LibreChat operator, I want conversation search powered by MeiliSearch to be an opt-in component, so that I can enable it only when the cost of running it is justified.

#### Acceptance Criteria

1. THE SAM_Template SHALL expose a deployment parameter (e.g., `EnableMeiliSearch`) that defaults to `false` and controls whether the MeiliSearch component is provisioned.
2. WHERE `EnableMeiliSearch` is `true`, THE Deployment_System SHALL deploy MeiliSearch as an ECS Fargate task within the VPC, accessible only from the Lambda_Function.
3. WHERE `EnableMeiliSearch` is `true`, THE MeiliSearch instance SHALL persist its index data to an Amazon EFS volume mounted to the Fargate task.
4. WHERE `EnableMeiliSearch` is `true`, THE Lambda_Function SHALL connect to MeiliSearch using the `MEILI_HOST` and `MEILI_MASTER_KEY` values sourced from Secrets_Manager.
5. WHERE `EnableMeiliSearch` is `true`, THE Deployment_System SHALL configure a security group for the MeiliSearch Fargate task that permits inbound connections only on port 7700 from the Lambda_Function security group.
6. IF `EnableMeiliSearch` is `false`, THEN THE Deployment_System SHALL set `SEARCH` to `false` in the Lambda_Function environment so that the conversation search feature is disabled and no MeiliSearch resources are provisioned.

---

### Requirement 11: MCP Server Support

**User Story:** As a LibreChat operator, I want MCP servers deployed as AWS Lambda functions within the same VPC, so that users can use tool integrations powered by the Model Context Protocol without the cost of long-running Fargate services.

#### Acceptance Criteria

1. THE Deployment_System SHALL deploy each MCP server as a dedicated MCP_Lambda function within the same VPC as the API Lambda_Function.
2. THE MCP_Lambda functions SHALL be deployed inside the VPC with security group rules that permit inbound connections only from the API Lambda_Function security group.
3. THE Lambda_Function SHALL reach MCP_Lambda endpoints over the VPC private network using Lambda function URLs or API_Gateway internal endpoints.
4. WHEN designing MCP servers for Lambda deployment, THE MCP_Lambda SHALL be stateless — all persistent state SHALL be stored in external services (e.g., ElastiCache, DocumentDB, or S3_Bucket) rather than in-process memory.
5. IF an MCP server operation requires state to be shared across invocations, THEN THE MCP_Lambda SHALL read and write that state to ElastiCache or DocumentDB within the VPC.
6. THE Deployment_System SHALL document the process for adding new MCP server configurations to the LibreChat `librechat.yaml` configuration file stored in Parameter_Store.

---

### Requirement 12: Infrastructure as Code

**User Story:** As a LibreChat operator, I want all AWS infrastructure defined as code using AWS SAM or CDK, so that the deployment is reproducible, version-controlled, and auditable.

#### Acceptance Criteria

1. THE Deployment_System SHALL define all AWS resources (Lambda, API Gateway, CloudFront, S3, DocumentDB, ElastiCache, VPC, IAM, SES, WAF) in a SAM_Template or CDK application.
2. THE SAM_Template SHALL support parameterized deployments for at least three environments: `dev`, `staging`, and `prod`.
3. THE Deployment_System SHALL include a CI/CD pipeline definition (GitHub Actions or AWS CodePipeline) that builds, tests, and deploys the application on each push to the main branch.
4. THE Deployment_System SHALL output the CloudFront distribution URL, API Gateway endpoint URL, and S3 bucket names as CloudFormation stack outputs after each deployment.
5. WHEN a deployment fails, THE Deployment_System SHALL automatically roll back to the previous stable stack version using CloudFormation rollback capabilities.
6. THE SAM_Template SHALL use SAM policy templates or inline IAM policies to grant Lambda the minimum required permissions for each AWS service it accesses.

---

### Requirement 13: Observability and Logging

**User Story:** As a LibreChat operator, I want centralized logs and metrics for all deployed components, so that I can monitor application health and diagnose issues.

#### Acceptance Criteria

1. THE Lambda_Function SHALL emit structured JSON logs to Amazon CloudWatch Logs by setting `CONSOLE_JSON=true` in the environment configuration.
2. THE Deployment_System SHALL configure a CloudWatch Log Group for the Lambda_Function with a retention period of at least 30 days.
3. THE Deployment_System SHALL create a CloudWatch Dashboard displaying Lambda invocation count, error rate, duration (p50/p95/p99), and throttle count.
4. THE API_Gateway SHALL have access logging enabled, writing to a dedicated CloudWatch Log Group.
5. WHEN the Lambda_Function error rate exceeds 5% over a 5-minute period, THE Deployment_System SHALL trigger a CloudWatch Alarm and send a notification to an SNS topic.
6. THE Deployment_System SHALL enable AWS X-Ray tracing on the Lambda_Function and API_Gateway for distributed request tracing.
