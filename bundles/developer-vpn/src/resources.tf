resource "massdriver_resource" "tunnel" {
  field = "tunnel"
  name  = "VPN ${local.name}"
  resource = jsonencode({
    interface = {
      private_key = wireguard_asymmetric_key.client.private_key
      address     = [local.client_address]
      dns         = [local.vpc_resolver]
    }
    peers = [{
      public_key           = wireguard_asymmetric_key.server.public_key
      preshared_key        = random_bytes.preshared_key.base64
      endpoint             = "${aws_eip.server.public_ip}:${local.port}"
      allowed_ips          = [var.network.cidr]
      persistent_keepalive = 25
    }]
  })
}
