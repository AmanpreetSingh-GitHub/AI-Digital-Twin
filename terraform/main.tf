# ============================================================
# AI Digital Twin Infrastructure
# AWS + OpenAI
# ============================================================

# Get current AWS account ID
data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}


# ============================================================
# S3 - Conversation Memory
# ============================================================

resource "aws_s3_bucket" "memory" {
  bucket = "${local.name_prefix}-memory-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "memory" {
  bucket = aws_s3_bucket.memory.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "memory" {
  bucket = aws_s3_bucket.memory.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}


# ============================================================
# S3 - Frontend Static Website
# ============================================================

resource "aws_s3_bucket" "frontend" {
  bucket = "${local.name_prefix}-frontend-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "404.html"
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
      }
    ]
  })

  depends_on = [
    aws_s3_bucket_public_access_block.frontend
  ]
}


# ============================================================
# IAM - Lambda Role
# ============================================================

resource "aws_iam_role" "lambda_role" {
  name = "${local.name_prefix}-lambda-role"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"

        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}


# CloudWatch logging permissions for Lambda
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}


# S3 access for conversation memory
resource "aws_iam_role_policy_attachment" "lambda_s3" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  role       = aws_iam_role.lambda_role.name
}


# ============================================================
# Lambda - FastAPI Backend
# ============================================================

resource "aws_lambda_function" "api" {
  filename         = "${path.module}/../backend/lambda-deployment.zip"
  function_name    = "${local.name_prefix}-api"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_handler.handler"
  source_code_hash = filebase64sha256("${path.module}/../backend/lambda-deployment.zip")

  runtime       = "python3.12"
  architectures = ["x86_64"]
  timeout       = var.lambda_timeout

  tags = local.common_tags

  environment {
    variables = {
      CORS_ORIGINS = "http://${aws_s3_bucket_website_configuration.frontend.website_endpoint}"
      S3_BUCKET    = aws_s3_bucket.memory.id
      USE_S3       = "true"
      OPENAI_MODEL = var.openai_model
    }
  }

  # OPENAI_API_KEY is currently configured manually
  # in the AWS Lambda console.
  #
  # Prevent Terraform from removing/changing the existing
  # Lambda environment variables, including OPENAI_API_KEY.
  lifecycle {
    ignore_changes = [
      environment
    ]
  }
}


# ============================================================
# API Gateway - HTTP API
# ============================================================

resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name_prefix}-api-gateway"
  protocol_type = "HTTP"

  tags = local.common_tags

  cors_configuration {
    allow_credentials = false
    allow_headers     = ["*"]
    allow_methods     = ["GET", "POST", "OPTIONS"]
    allow_origins     = ["*"]
    max_age           = 300
  }
}


resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  tags = local.common_tags

  default_route_settings {
    throttling_burst_limit = var.api_throttle_burst_limit
    throttling_rate_limit  = var.api_throttle_rate_limit
  }
}


resource "aws_apigatewayv2_integration" "lambda" {
  api_id = aws_apigatewayv2_api.main.id

  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.api.invoke_arn
}


# ============================================================
# API Gateway Routes
# ============================================================

resource "aws_apigatewayv2_route" "get_root" {
  api_id = aws_apigatewayv2_api.main.id

  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}


resource "aws_apigatewayv2_route" "post_chat" {
  api_id = aws_apigatewayv2_api.main.id

  route_key = "POST /chat"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}


resource "aws_apigatewayv2_route" "get_health" {
  api_id = aws_apigatewayv2_api.main.id

  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}


# ============================================================
# Allow API Gateway to invoke Lambda
# ============================================================

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}