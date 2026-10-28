# ECS Fargate — production-shaped starter stack (lab / demo)
# Region, image and sizing are variables on purpose: change them, don't fork the file.
# WARNING: this creates billable resources (ALB, NAT). Run `terraform destroy` when done.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "region" { default = "ap-southeast-1" } # Singapore — closest to Indonesia
variable "image" { default = "nginx:latest" }   # swap for your own ECR image
variable "task_cpu" { default = "512" }          # 0.5 vCPU — start small, measure, then scale
variable "task_memory" { default = "1024" }      # 1 GB (must be a valid Fargate pair)
variable "desired_count" { default = 2 }

provider "aws" { region = var.region }

data "aws_availability_zones" "available" { state = "available" }

# --- Networking: public subnets for the ALB, private subnets for tasks ---
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "fargate-demo" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "fargate-demo-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = { Name = "fargate-demo-private-${count.index}" }
}

resource "aws_internet_gateway" "main" { vpc_id = aws_vpc.main.id }

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0", gateway_id = aws_internet_gateway.main.id }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Security: ALB is the ONLY inbound source for tasks ---
resource "aws_security_group" "alb" {
  name_prefix = "fargate-alb-"
  vpc_id      = aws_vpc.main.id
  ingress { from_port = 80, to_port = 80, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "task" {
  name_prefix = "fargate-task-"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id] # nothing else can reach the task
  }
  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }
}

# --- Load balancer ---
resource "aws_lb" "main" {
  name               = "fargate-demo-alb"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "api" {
  name        = "fargate-demo-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id
  health_check { path = "/", healthy_threshold = 2, unhealthy_threshold = 3 }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action { type = "forward", target_group_arn = aws_lb_target_group.api.arn }
}

# --- IAM: execution role (ECS pulls image + writes logs) vs task role (app identity) ---
resource "aws_iam_role" "execution" {
  name = "fargate-demo-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name = "fargate-demo-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
# Attach ONLY the permissions your app actually needs — nothing here by default, on purpose.

# --- ECS: cluster, logs, task definition, service ---
resource "aws_ecs_cluster" "main" { name = "fargate-demo" }

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/fargate-demo-api"
  retention_in_days = 7 # crashed-task logs vanish with the task if you skip this
}

resource "aws_ecs_task_definition" "api" {
  family                   = "fargate-demo-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name  = "api"
    image = var.image
    portMappings = [{ containerPort = 80, protocol = "tcp" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "api"
      }
    }
  }])
}

resource "aws_ecs_service" "api" {
  name            = "api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false # tasks are never directly reachable
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 80
  }

  health_check_grace_period_seconds = 60 # don't kill slow-warming tasks in a loop
  depends_on = [aws_lb_listener.http]
}

# --- Autoscaling: CPU + ALB request count (CPU alone misses I/O-bound saturation) ---
resource "aws_appautoscaling_target" "api" {
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
  min_capacity       = 2
  max_capacity       = 6
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "fargate-demo-cpu"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  policy_type        = "TargetTrackingScaling"
  target_tracking_scaling_policy_configuration {
    target_value = 70.0
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
  }
}

output "alb_dns_name" {
  description = "Open http://<this> to reach the service (swap to HTTPS + ACM in production)"
  value       = aws_lb.main.dns_name
}
