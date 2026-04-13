resource "aws_db_subnet_group" "metabase" {
  name        = "${local.name_prefix}-db-subnet-group"
  description = "Private subnets for Metabase RDS"
  subnet_ids  = aws_subnet.private_db[*].id
  tags        = { Name = "${local.name_prefix}-db-subnet-group" }
}

resource "aws_db_parameter_group" "metabase" {
  name        = "${local.name_prefix}-pg15-params"
  family      = "postgres15"
  description = "PostgreSQL 15 for Metabase"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = { Name = "${local.name_prefix}-pg15-params" }
}

resource "aws_db_instance" "metabase" {
  identifier     = "${local.name_prefix}-postgres"
  engine         = "postgres"
  engine_version = "15.7"
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result

  db_subnet_group_name   = aws_db_subnet_group.metabase.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az               = var.db_multi_az
  parameter_group_name   = aws_db_parameter_group.metabase.name

  backup_retention_period    = var.db_backup_retention_days
  backup_window              = "18:00-19:00"
  maintenance_window         = "Mon:19:00-Mon:20:00"
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-final-snapshot"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn

  tags = { Name = "${local.name_prefix}-postgres" }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = []

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.metabase.id
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${local.name_prefix}-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 5368709120
  alarm_actions       = []

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.metabase.id
  }
}
