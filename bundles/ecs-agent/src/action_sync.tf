resource "massdriver_event_destination" "actions" {
  count = var.action_sync.enabled ? 1 : 0

  name    = "${local.name}-actions"
  adapter = "HTTP"
  config  = jsonencode({ url = var.action_sync.url })

  # Events about service accounts and groups carry no attributes, so any
  # type or attribute filter would drop some of the agent's actions. The actor
  # is the only thing every one of them shares: the service account that made
  # the change, or that started the deployment.
  event_types = []
  attributes  = {}
  condition   = ".data.actor.service_account_id == ${jsonencode(massdriver_service_account.agent.id)}"

  lifecycle {
    precondition {
      condition     = var.action_sync.url != ""
      error_message = "Set Webhook URL, or turn off Send actions."
    }
  }
}

# The receiver checks each request's webhook-signature header with this.
resource "aws_secretsmanager_secret" "action_sync" {
  count = var.action_sync.enabled ? 1 : 0

  name_prefix             = "${local.name}-actions-"
  description             = "Signing secret of ${local.name}'s action webhook"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "action_sync" {
  count = var.action_sync.enabled ? 1 : 0

  secret_id     = aws_secretsmanager_secret.action_sync[0].id
  secret_string = massdriver_event_destination.actions[0].signing_secret
}
