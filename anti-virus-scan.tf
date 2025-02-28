#
# Lambda Function: Anti-Virus Scanning
#

#
# IAM
#

data "aws_iam_policy_document" "assume_role_scan" {
  statement {
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "main_scan" {
  # Allow creating and writing CloudWatch logs for Lambda function.
  statement {
    sid = "WriteCloudWatchLogs"

    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_scan}:*"]
  }

  statement {
    sid = "s3AntiVirusScan"

    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:PutObjectTagging",
      "s3:PutObjectVersionTagging",
    ]

    resources = formatlist("%s/*", data.aws_s3_bucket.main_scan.*.arn)
  }

  statement {
    sid = "s3AntiVirusDefinitions"

    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
    ]

    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.av_definition_s3_bucket}/${var.av_definition_s3_prefix}/*"]
  }

  statement {
    sid = "s3HeadObject"

    effect = "Allow"

    actions = [
      "s3:ListBucket",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.av_definition_s3_bucket}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.av_definition_s3_bucket}/*",
    ]
  }

  statement {
    sid = "kmsDecrypt"

    effect = "Allow"

    actions = [
      "kms:Decrypt",
    ]

    resources = formatlist("%s/*", data.aws_s3_bucket.main_scan.*.arn)
  }

  # statement {
  #   sid = "snsPublish"

  #   effect = "Allow"

  #   actions = [
  #     "sns:Publish",
  #   ]

  #   resources = compact([var.av_scan_start_sns_arn, var.av_status_sns_arn])
  # }
}

resource "aws_iam_role" "main_scan" {
  name               = "lambda-${var.name_scan}"
  assume_role_policy = data.aws_iam_policy_document.assume_role_scan.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "main_scan" {
  name = "lambda-${var.name_scan}"
  role = aws_iam_role.main_scan.id

  policy = data.aws_iam_policy_document.main_scan.json
}

#
# S3 Event
#

data "aws_s3_bucket" "main_scan" {
  count  = length(var.av_scan_buckets)
  bucket = var.av_scan_buckets[count.index]
}

resource "aws_s3_bucket_notification" "main_scan" {
  count  = length(var.av_scan_buckets)
  bucket = element(data.aws_s3_bucket.main_scan.*.id, count.index)
  dynamic "lambda_function" {
    for_each = length(var.av_filter_prefixes) > 0 ? toset(var.av_filter_prefixes) : [""]
    content {
      id                  = element(data.aws_s3_bucket.main_scan.*.id, count.index)
      lambda_function_arn = aws_lambda_function.main_scan.arn
      events              = ["s3:ObjectCreated:*"]
      filter_prefix       = lambda_function.key
    }
  }
}

#
# CloudWatch Logs
#

resource "aws_cloudwatch_log_group" "main_scan" {
  # This name must match the lambda function name and should not be changed
  name              = "/aws/lambda/${var.name_scan}"
  retention_in_days = var.cloudwatch_logs_retention_days

  tags = merge(
    {
      "Name" = var.name_scan
    },
    var.tags
  )
}

#
# Lambda Function
#

resource "aws_lambda_function" "main_scan" {
  depends_on = [aws_cloudwatch_log_group.main_scan]

  description = "Scans s3 objects with clamav for viruses."

  filename         = "./files/lambda.zip"
  source_code_hash = filebase64sha256("./files/lambda.zip")

  function_name = var.name_scan
  role          = aws_iam_role.main_scan.arn
  handler       = "scan.lambda_handler"
  runtime       = "python3.7"
  memory_size   = var.memory_size
  timeout       = var.timeout_seconds

  environment {
    variables = {
      AV_DEFINITION_S3_BUCKET        = var.av_definition_s3_bucket
      AV_DEFINITION_S3_PREFIX        = var.av_definition_s3_prefix
      AV_SCAN_START_SNS_ARN          = var.av_scan_start_sns_arn
      AV_STATUS_SNS_ARN              = var.av_status_sns_arn
      AV_STATUS_SNS_PUBLISH_CLEAN    = var.av_status_sns_publish_clean
      AV_STATUS_SNS_PUBLISH_INFECTED = var.av_status_sns_publish_infected
    }
  }

  tags = merge(
    {
      "Name" = var.name_scan
    },
    var.tags
  )
}

resource "aws_lambda_permission" "main_scan" {
  count = length(var.av_scan_buckets)

  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.main_scan.function_name

  principal = "s3.amazonaws.com"

  source_account = data.aws_caller_identity.current.account_id
  source_arn     = element(data.aws_s3_bucket.main_scan.*.arn, count.index)

  statement_id = replace("${var.name_scan}-${element(data.aws_s3_bucket.main_scan.*.id, count.index)}", ".", "-")
}
