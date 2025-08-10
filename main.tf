# terraform/main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  backend "s3" {
    bucket = "flask-app-terraform-state-073687477291"
    key    = "flask-app/terraform.tfstate"
    region = "us-west-2"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC and Networking
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name        = "flask-app-vpc"
    Environment = var.environment
  }
}

resource "aws_subnet" "public" {
  count = 2
  
  vpc_id                  = aws_vpc.main.id
  cidr_block             = "10.0.${count.index + 1}.0/24"
  availability_zone      = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  
  tags = {
    Name = "flask-app-public-subnet-${count.index + 1}"
  }
}

# Security Groups
resource "aws_security_group" "alb" {
  name_prefix = "flask-app-alb-"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "flask-app-alb-sg"
  }
}

resource "aws_security_group" "ecs" {
  name_prefix = "flask-app-ecs-"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "flask-app-ecs-sg"
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "flask-app-cluster"
  
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  
  tags = {
    Environment = var.environment
  }
}

# ECS Task Definition
resource "aws_ecs_task_definition" "flask_app" {
  family                   = "flask-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn           = aws_iam_role.ecs_task_role.arn
  
  container_definitions = jsonencode([
    {
      name  = "flask-app"
      image = "${var.docker_image}:${var.image_tag}"
      
      portMappings = [
        {
          containerPort = 5000
          protocol      = "tcp"
        }
      ]
      
      healthCheck = {
        command = ["CMD-SHELL", "curl -f http://localhost:5000/health || exit 1"]
        interval = 30
        timeout = 5
        retries = 3
        startPeriod = 60
      }
      
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.flask_app.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
      
      environment = [
        {
          name  = "ENVIRONMENT"
          value = var.environment
        }
      ]
      
      essential = true
    }
  ])
  
  tags = {
    Environment = var.environment
  }
}

# CloudWatch Logs
resource "aws_cloudwatch_log_group" "flask_app" {
  name              = "/ecs/flask-app"
  retention_in_days = 7
  
  tags = {
    Environment = var.environment
  }
}

# Application Load Balancer
resource "aws_lb" "flask_app" {
  name               = "flask-app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  
  enable_deletion_protection = false
  
  tags = {
    Environment = var.environment
  }
}

resource "aws_lb_target_group" "flask_app" {
  name        = "flask-app-tg"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }
  
  tags = {
    Environment = var.environment
  }
}

resource "aws_lb_listener" "flask_app" {
  load_balancer_arn = aws_lb.flask_app.arn
  port              = "80"
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.flask_app.arn
  }
}

# ECS Service
resource "aws_ecs_service" "flask_app" {
  name            = "flask-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.flask_app.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  
  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs.id]
    assign_public_ip = true
  }
  
  load_balancer {
    target_group_arn = aws_lb_target_group.flask_app.arn
    container_name   = "flask-app"
    container_port   = 5000
  }
  
  depends_on = [aws_lb_listener.flask_app]
  
  tags = {
    Environment = var.environment
  }
}

# Outputs
output "load_balancer_url" {
  description = "URL of the load balancer"
  value       = "http://${aws_lb.flask_app.dns_name}"
}

output "load_balancer_dns_name" {
  description = "DNS name of the load balancer"
  value       = aws_lb.flask_app.dns_name
}