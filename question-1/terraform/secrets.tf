resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%^&*-_=+"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${local.name_prefix}/db/credentials"
  description             = "Metabase PostgreSQL credentials"
  recovery_window_in_days = 7
  tags                    = { Name = "${local.name_prefix}-db-credentials" }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    host     = aws_db_instance.metabase.address
    port     = tostring(aws_db_instance.metabase.port)
    dbname   = var.db_name
    engine   = "postgres"
  })

  depends_on = [aws_db_instance.metabase]
}

resource "aws_secretsmanager_secret_policy" "db_credentials" {
  secret_arn = aws_secretsmanager_secret.db_credentials.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowECSExecutionRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.ecs_execution.arn
        }
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "*"
      }
    ]
  })

  depends_on = [aws_iam_role.ecs_execution]
}
