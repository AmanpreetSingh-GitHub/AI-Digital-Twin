param(
    [string]$Environment = "dev",   # dev | test | prod
    [string]$ProjectName = "twin"
)

$ErrorActionPreference = "Stop"

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

# 1. Build Lambda package
Set-Location (Split-Path $PSScriptRoot -Parent)
Write-Host "Building Lambda package..." -ForegroundColor Yellow

Set-Location backend
uv run deploy.py
Set-Location ..

# 2. Terraform workspace & apply
Set-Location terraform

$awsAccountId = aws sts get-caller-identity --query Account --output text
$awsRegion = if ($env:DEFAULT_AWS_REGION) { $env:DEFAULT_AWS_REGION } else { "us-east-1" }
terraform init -input=false `
  -backend-config="bucket=twin-terraform-state-$awsAccountId" `
  -backend-config="key=$Environment/terraform.tfstate" `
  -backend-config="region=$awsRegion" `
  -backend-config="dynamodb_table=twin-terraform-locks" `
  -backend-config="encrypt=true"

if (-not (terraform workspace list | Select-String $Environment)) {
    terraform workspace new $Environment
} else {
    terraform workspace select $Environment
}

if ($Environment -eq "prod") {
    terraform apply `
        -var-file="prod.tfvars" `
        -var="project_name=$ProjectName" `
        -var="environment=$Environment" `
        -auto-approve
} else {
    terraform apply `
        -var="project_name=$ProjectName" `
        -var="environment=$Environment" `
        -auto-approve
}

$ApiUrl         = terraform output -raw api_gateway_url
$FrontendBucket = terraform output -raw s3_frontend_bucket

# 3. Build + deploy frontend
Set-Location ..\frontend

Write-Host "Setting API URL for production..." -ForegroundColor Yellow

"NEXT_PUBLIC_API_URL=$ApiUrl" | Out-File .env.production -Encoding utf8

npm install

Remove-Item -Recurse -Force .next -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force out -ErrorAction SilentlyContinue

npm run build

aws s3 sync .\out "s3://$FrontendBucket/" --delete

Set-Location ..

# 4. Final summary
$FrontendUrl = terraform -chdir=terraform output -raw s3_frontend_url

Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "Frontend       : $FrontendUrl" -ForegroundColor Cyan
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan