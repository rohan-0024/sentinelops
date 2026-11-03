# FinOps Autopilot: a Lambda that scales the EKS node group to zero and stops
# Schedule=office-hours instances outside working hours. Override by setting the
# SSM parameter /<name>/finops/override to "keep-alive".

data "archive_file" "lambda" {
  type        = "zip"
  source_file = var.handler_source_file
  output_path = "${path.module}/.build/finops_lambda.zip"
}

resource "aws_ssm_parameter" "override" {
  # checkov:skip=CKV2_AWS_34:Value is a non-secret on/off flag, SecureString is unnecessary
  name        = "/${var.name}/finops/override"
  description = "Set to keep-alive to skip scheduled teardown"
  type        = "String"
  value       = "off"
  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-finops-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = var.kms_key_arn
}

resource "aws_cloudwatch_log_group" "lambda" {
  # checkov:skip=CKV_AWS_338:14-day retention is sufficient for a scheduler audit trail in a lab
  name              = "/aws/lambda/${var.name}-finops-autopilot"
  retention_in_days = 14
  kms_key_id        = var.kms_key_arn
}

resource "aws_lambda_function" "autopilot" {
  # checkov:skip=CKV_AWS_117:Function only calls AWS APIs; VPC attachment would require NAT/endpoints for no security gain
  # checkov:skip=CKV_AWS_272:Code signing requires AWS Signer profiles, not available in AWS Academy
  function_name                  = "${var.name}-finops-autopilot"
  role                           = var.lambda_role_arn
  runtime                        = "python3.12"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.lambda.output_path
  source_code_hash               = data.archive_file.lambda.output_base64sha256
  timeout                        = 60
  memory_size                    = 128
  reserved_concurrent_executions = var.reserved_concurrency
  kms_key_arn                    = var.kms_key_arn

  environment {
    variables = {
      CLUSTER_NAME      = var.cluster_name
      NODEGROUP_NAME    = var.nodegroup_name
      DEFAULT_DESIRED   = tostring(var.default_desired)
      SCHEDULE_TAG      = "office-hours"
      PARAM_PREFIX      = "/${var.name}/finops"
      DRY_RUN           = tostring(var.dry_run)
      INSTANCE_ID_ALLOW = join(",", var.instance_ids)
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

locals {
  schedules = {
    stop  = { cron = var.stop_cron, enabled = true }
    start = { cron = var.start_cron, enabled = var.enable_auto_start }
  }
}

resource "aws_cloudwatch_event_rule" "schedule" {
  for_each            = local.schedules
  name                = "${var.name}-finops-${each.key}"
  description         = "FinOps autopilot: ${each.key} (cron in UTC)"
  schedule_expression = "cron(${each.value.cron})"
  state               = each.value.enabled ? "ENABLED" : "DISABLED"
}

resource "aws_cloudwatch_event_target" "schedule" {
  for_each = local.schedules
  rule     = aws_cloudwatch_event_rule.schedule[each.key].name
  arn      = aws_lambda_function.autopilot.arn
  input    = jsonencode({ action = each.key, source = "eventbridge" })
}

resource "aws_lambda_permission" "events" {
  for_each      = local.schedules
  statement_id  = "AllowEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.autopilot.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule[each.key].arn
}
