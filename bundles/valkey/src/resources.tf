resource "massdriver_resource" "cache" {
  field = "cache"
  name  = "Valkey ${local.name}"
  resource = jsonencode({
    name                     = aws_elasticache_serverless_cache.main.name
    region                   = var.network.region
    hostname                 = aws_elasticache_serverless_cache.main.endpoint[0].address
    port                     = aws_elasticache_serverless_cache.main.endpoint[0].port
    reader_hostname          = aws_elasticache_serverless_cache.main.reader_endpoint[0].address
    client_security_group_id = aws_security_group.client.id
  })
}
