# Developer VPN

A WireGuard tunnel from one developer's laptop into the environment's VPC. Use it in a developer sandbox to reach private databases, caches and services without a bastion host or SSH keys.

## What it needs

- An AWS account to deploy into.
- A VPC with at least one public subnet. In a sandbox, the VPC comes from the environment default, so the developer does not connect anything.

## What it makes

- A small EC2 server running WireGuard in a public subnet, with a fixed public IP.
- A key pair for the server and one for the laptop, plus a shared extra key. The server's keys stay in Parameter Store; the laptop's are in the **tunnel** resource.
- A **tunnel** resource. Download `wg0.conf` from it and import it into the WireGuard app.

## Cost

About $7 a month: ~$3 for a t4g.nano and ~$3.65 for its public IP, plus data sent out of AWS.

## Limits

- One laptop per deployment. A second laptop needs its own deployment.
- Traffic reaches the VPC from the server's private IP and security group. A database or cache that allows only its own client security group will not accept it until that group is attached to the server or allows the server's group.
- Decommissioning removes the server and the keys. The old `wg0.conf` stops working right away.
