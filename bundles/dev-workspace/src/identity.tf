# Named after the sandbox, so the audit log shows whose workspace acted.
resource "massdriver_service_account" "workspace" {
  name        = var.md_metadata.name_prefix
  description = "The developer workspace ${var.md_metadata.name_prefix}. Its groups are set on that instance."
  # The token lives only in this instance's state and the task's secret.
  # Replacing the instance's service account is how it rotates.
  token_expiration_minutes = 60 * 24 * 365 * 10
}

resource "massdriver_service_account_group_membership" "workspace" {
  for_each = toset(var.groups)

  group_id           = each.value
  service_account_id = massdriver_service_account.workspace.id
}
