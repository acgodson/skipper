resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = local.name }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# The whole inbound surface: Caddy's two ports and coturn's. There is no SSH rule;
# a shell comes from SSM Session Manager over the instance's outbound connection.
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Caddy and coturn only; no inbound SSH"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.app.id
  description       = "Caddy: ACME HTTP-01 and the redirect to https"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "Caddy: the REST API and the signaling WebSocket"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "turn_tcp" {
  security_group_id = aws_security_group.app.id
  description       = "coturn control, tcp"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = var.turn_listen_port
  to_port           = var.turn_listen_port
}

resource "aws_vpc_security_group_ingress_rule" "turn_udp" {
  security_group_id = aws_security_group.app.id
  description       = "coturn control, udp"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = var.turn_listen_port
  to_port           = var.turn_listen_port
}

resource "aws_vpc_security_group_ingress_rule" "turn_relay" {
  security_group_id = aws_security_group.app.id
  description       = "coturn relay range"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = var.turn_relay_min_port
  to_port           = var.turn_relay_max_port
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "ACME, SSM, CloudWatch, SSM Parameter Store, S3, and the relay return path"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Created on its own, so the instance's userdata can name the address it will answer on
# without a cycle. The owner adds the api and turn A records at the registrar by hand.
resource "aws_eip" "this" {
  domain = "vpc"

  tags = { Name = local.name }
}

resource "aws_eip_association" "this" {
  allocation_id = aws_eip.this.id
  instance_id   = aws_instance.app.id
}
