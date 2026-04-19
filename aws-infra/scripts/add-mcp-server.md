# Adding a New MCP Server

This guide describes how to add a new MCP server to the LibreChat deployment. Each MCP server runs as a dedicated Lambda function inside the VPC and is invoked by the API Lambda via a Function URL with IAM authentication (SigV4).

## Prerequisites

- AWS SAM CLI installed
- AWS credentials configured for the target environment
- The base infrastructure stack (`librechat-{env}`) is deployed

## Steps

### 1. Add a SAM resource in `aws-infra/mcp/template.yaml`

Add a new `AWS::Serverless::Function` resource. Use the shared `MCPLambdaRole` and the `Globals` section already defines the VPC config, runtime, and timeout.

```yaml
  MyNewMCPFunction:
    Type: AWS::Serverless::Function
    Properties:
      FunctionName: !Sub librechat-${Environment}-mcp-my-new-server
      Description: My new MCP server
      Handler: index.handler
      CodeUri: handlers/my-new-server/
      Role: !GetAtt MCPLambdaRole.Arn
      FunctionUrlConfig:
        AuthType: AWS_IAM
```

Create the handler at `aws-infra/mcp/handlers/my-new-server/index.js` (or `.py` for Python runtimes — override `Runtime` on the resource if needed).

Add an output for the new function URL:

```yaml
  MyNewMCPFunctionUrl:
    Description: Function URL of MyNewMCP
    Value: !GetAtt MyNewMCPFunctionUrl.FunctionUrl
    Export:
      Name: !Sub librechat-${Environment}-MyNewMCPFunctionUrl
```

### 2. Update `librechat.yaml` in SSM Parameter Store

After deploying, grab the new function URL from the stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name librechat-{env}-MCPStack \
  --query "Stacks[0].Outputs[?OutputKey=='MyNewMCPFunctionUrl'].OutputValue" \
  --output text
```

Then update the `librechat_yaml` SSM parameter to include the new MCP server:

```bash
# Fetch current value
aws ssm get-parameter \
  --name "/librechat/{env}/config/librechat_yaml" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text > librechat.yaml

# Edit librechat.yaml — add the new MCP server entry under mcpServers:
#
#   mcpServers:
#     my-new-server:
#       url: <function-url-from-step-above>
#       type: sse

# Push updated value
aws ssm put-parameter \
  --name "/librechat/{env}/config/librechat_yaml" \
  --type SecureString \
  --value file://librechat.yaml \
  --overwrite
```

### 3. Deploy

```bash
sam build --config-env {env}
sam deploy --config-env {env} --no-confirm-changeset
```

The API Lambda does not need redeployment — it reads `librechat.yaml` from SSM Parameter Store at cold start and will pick up the new MCP server configuration automatically on the next cold start.

## Notes

- MCP Lambdas are stateless. Store any shared state in ElastiCache or DocumentDB.
- The shared `MCPLambdaRole` already grants `secretsmanager:GetSecretValue`, `elasticache:Connect`, and VPC ENI permissions. If your MCP server needs additional permissions (e.g., S3, DynamoDB), add a dedicated policy to the role or create a separate role.
- The `sg-mcp` security group allows inbound 443 from `sg-lambda` and outbound to the internet, DocumentDB, and ElastiCache.
- Default timeout is 60 seconds (set in `Globals`). Override per-function if needed.
