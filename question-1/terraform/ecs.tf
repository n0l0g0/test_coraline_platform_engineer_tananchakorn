resource "aws_cloudwatch_log_group" "metabase" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 30
  tags              = { Name = "${local.name_prefix}-logs" }
}

resource "aws_ecs_cluster" "metabase" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${local.name_prefix}-cluster" }
}

resource "aws_ecs_cluster_capacity_providers" "metabase" {
  cluster_name       = aws_ecs_cluster.metabase.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

resource "aws_ecs_task_definition" "metabase" {
  family                   = local.name_prefix
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.metabase_cpu
  memory                   = var.metabase_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "metabase"
    image     = var.metabase_image
    essential = true

    portMappings = [{
      containerPort = var.metabase_port
      hostPort      = var.metabase_port
      protocol      = "tcp"
    }]

    environment = [
      { name = "MB_DB_TYPE",   value = "postgres" },
      { name = "MB_DB_DBNAME", value = var.db_name },
      { name = "MB_DB_PORT",   value = "5432" },
      { name = "MB_DB_HOST",   value = aws_db_instance.metabase.address },
      { name = "JAVA_TIMEZONE", value = "Asia/Bangkok" },
    ]

    # Secrets fetched from Secrets Manager at task startup — not stored in task def
    secrets = [
      {
        name      = "MB_DB_USER"
        valueFrom = "${aws_secretsmanager_secret.db_credentials.arn}:username::"
      },
      {
        name      = "MB_DB_PASS"
        valueFrom = "${aws_secretsmanager_secret.db_credentials.arn}:password::"
      }
    ]

    healthCheck = {
      command     = ["CMD-SHELL", "curl -fs http://localhost:${var.metabase_port}/api/health || exit 1"]
      interval    = 30
      timeout     = 10
      retries     = 5
      startPeriod = 120
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.metabase.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "metabase"
      }
    }

    linuxParameters = {
      capabilities       = { drop = ["ALL"], add = [] }
      initProcessEnabled = true
    }

    user = "2000"
  }])

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_ecs_service" "metabase" {
  name                              = local.name_prefix
  cluster                           = aws_ecs_cluster.metabase.id
  task_definition                   = aws_ecs_task_definition.metabase.arn
  desired_count                     = var.metabase_desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 180

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_controller { type = "ECS" }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.metabase.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.metabase.arn
    container_name   = "metabase"
    container_port   = var.metabase_port
  }

  depends_on = [
    aws_lb_listener.https,
    aws_iam_role_policy_attachment.ecs_execution_managed
  ]

  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_appautoscaling_target" "metabase" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.metabase.name}/${aws_ecs_service.metabase.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "metabase_cpu" {
  name               = "${local.name_prefix}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.metabase.resource_id
  scalable_dimension = aws_appautoscaling_target.metabase.scalable_dimension
  service_namespace  = aws_appautoscaling_target.metabase.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "metabase_memory" {
  name               = "${local.name_prefix}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.metabase.resource_id
  scalable_dimension = aws_appautoscaling_target.metabase.scalable_dimension
  service_namespace  = aws_appautoscaling_target.metabase.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 80.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}
