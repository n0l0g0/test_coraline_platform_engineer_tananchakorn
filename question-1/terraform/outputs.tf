output "metabase_url" {
  value = "https://${aws_lb.metabase.dns_name}"
}

output "alb_dns_name" {
  value = aws_lb.metabase.dns_name
}

output "alb_zone_id" {
  value = aws_lb.metabase.zone_id
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "rds_endpoint" {
  value     = aws_db_instance.metabase.address
  sensitive = true
}

output "rds_identifier" {
  value = aws_db_instance.metabase.identifier
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.metabase.name
}

output "ecs_service_name" {
  value = aws_ecs_service.metabase.name
}

output "db_secret_arn" {
  value     = aws_secretsmanager_secret.db_credentials.arn
  sensitive = true
}

output "cloudwatch_log_group" {
  value = aws_cloudwatch_log_group.metabase.name
}
