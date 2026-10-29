# Security alerting on CloudTrail management events (requires an account or
# organization CloudTrail; most accounts already have one):
#   - KMS key disabled or scheduled for deletion
#   - break-glass role assumed
#   - Secrets Manager value read by an unexpected principal
# Alerts go to an encrypted SNS topic.
resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-security-alerts"
  kms_master_key_id = var.kms_key_arn
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

data "aws_iam_policy_document" "topic" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.topic.json
}

locals {
  rules = {
    kms-key-disable-or-delete = {
      description = "A KMS key was disabled or scheduled for deletion"
      pattern = {
        source        = ["aws.kms"]
        "detail-type" = ["AWS API Call via CloudTrail"]
        detail        = { eventName = ["DisableKey", "ScheduleKeyDeletion"] }
      }
    }
    break-glass-assumed = {
      description = "The EKS break-glass role was assumed"
      pattern = {
        source        = ["aws.sts"]
        "detail-type" = ["AWS API Call via CloudTrail"]
        detail        = { eventName = ["AssumeRole"], requestParameters = { roleArn = [var.breakglass_role_arn] } }
      }
    }
    unexpected-secret-read = {
      description = "A Secrets Manager value was read by a principal other than the expected readers"
      pattern = {
        source        = ["aws.secretsmanager"]
        "detail-type" = ["AWS API Call via CloudTrail"]
        detail = {
          eventName    = ["GetSecretValue"]
          userIdentity = { sessionContext = { sessionIssuer = { arn = [{ "anything-but" = var.expected_secret_reader_arns }] } } }
        }
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each      = local.rules
  name          = "${var.name}-${each.key}"
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)
  tags          = var.tags
}

resource "aws_cloudwatch_event_target" "sns" {
  for_each = aws_cloudwatch_event_rule.this
  rule     = each.value.name
  arn      = aws_sns_topic.alerts.arn
}
