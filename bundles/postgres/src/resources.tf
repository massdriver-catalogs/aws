# Consumers attach client_security_group_id to their tasks and the read-secret
# policy to their role, so the database owns both its network and secret access.
resource "massdriver_resource" "database" {
  field = "database"
  name  = "PostgreSQL ${local.name}"
  resource = jsonencode({
    id                       = aws_db_instance.main.identifier
    region                   = var.network.region
    hostname                 = aws_db_instance.main.address
    port                     = aws_db_instance.main.port
    database                 = aws_db_instance.main.db_name
    username                 = aws_db_instance.main.username
    password                 = random_password.main.result
    secret_arn               = aws_secretsmanager_secret.main.arn
    client_security_group_id = aws_security_group.client.id
    policies = [
      { name = "read-secret", arn = aws_iam_policy.read_secret.arn },
    ]
  })
}
