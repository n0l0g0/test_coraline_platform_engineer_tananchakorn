resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB inbound HTTP/HTTPS, outbound to Metabase only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port       = var.metabase_port
    to_port         = var.metabase_port
    protocol        = "tcp"
    security_groups = [aws_security_group.metabase.id]
  }

  tags = { Name = "${local.name_prefix}-alb-sg" }
}

resource "aws_security_group" "metabase" {
  name        = "${local.name_prefix}-metabase-sg"
  description = "Metabase ECS tasks — inbound from ALB, outbound to RDS + AWS services"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = var.metabase_port
    to_port         = var.metabase_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds.id]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-metabase-sg" }
}

# RDS only accepts connections from Metabase tasks
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "RDS PostgreSQL — inbound from Metabase ECS only, no egress"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.metabase.id]
  }

  tags = { Name = "${local.name_prefix}-rds-sg" }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name_prefix}-vpce-sg"
  description = "VPC Interface Endpoints — HTTPS from Metabase tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.metabase.id]
  }

  tags = { Name = "${local.name_prefix}-vpce-sg" }
}
