resource "massdriver_resource" "lab" {
  field = "lab"
  name  = "Lab box ${local.name}"
  resource = jsonencode({
    hostname          = local.hostname
    agent_url         = "http://${local.hostname}:${local.agent_port}"
    game_url          = "http://${local.hostname}:${local.game_port}/play/"
    agent             = "opencode"
    region            = var.cluster.region
    security_group_id = aws_security_group.task.id
  })
}
