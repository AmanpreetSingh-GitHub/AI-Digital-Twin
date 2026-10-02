#!/usr/bin/env bash

set -euo pipefail

ENVIRONMENT="${1:-dev}"
PROJECT_NAME="${2:-twin}"

if [[ ! "$ENVIRONMENT" =~ ^(dev|test|prod)$ ]]; then
    echo "Error: Invalid environment '$ENVIRONMENT'"
    echo "Available environments: dev, test, prod"
    exit 1
fi

echo "Deploying $PROJECT_NAME to $ENVIRONMENT ..."

# Get project root regardless of where script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1. Build Lambda package
echo "Building Lambda package..."

cd "$PROJECT_ROOT/backend"
uv run deploy.py

# 2. Terraform workspace & apply
cd "$PROJECT_ROOT/terraform"

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
AWS_REGION="${DEFAULT_AWS_REGION:-us-east-1}"

echo "Initializing Terraform with S3 backend..."

terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-$AWS_ACCOUNT_ID" \
  -backend-config="key=$ENVIRONMENT/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

if terraform workspace list | sed 's/^[* ]*//' | grep -Fxq "$ENVIRONMENT"; then
    terraform workspace select "$ENVIRONMENT"
else
    terraform workspace new "$ENVIRONMENT"
fi

echo "Applying Terraform infrastructure..."

if [[ "$ENVIRONMENT" == "prod" && -f "prod.tfvars" ]]; then
    terraform apply \
        -var-file="prod.tfvars" \
        -var="project_name=$PROJECT_NAME" \
        -var="environment=$ENVIRONMENT" \
        -auto-approve
else
    terraform apply \
        -var="project_name=$PROJECT_NAME" \
        -var="environment=$ENVIRONMENT" \
        -auto-approve
fi

API_URL="$(terraform output -raw api_gateway_url)"
FRONTEND_BUCKET="$(terraform output -raw s3_frontend_bucket)"

# 3. Build + deploy frontend
cd "$PROJECT_ROOT/frontend"

echo "Setting API URL for production..."

printf 'NEXT_PUBLIC_API_URL=%s\n' "$API_URL" > .env.production

npm install

rm -rf .next
rm -rf out

npm run build

aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete

# 4. Final summary
cd "$PROJECT_ROOT/terraform"

FRONTEND_URL="$(terraform output -raw s3_frontend_url)"

echo ""
echo "Deployment complete!"
echo "Frontend       : $FRONTEND_URL"
echo "API Gateway    : $API_URL"