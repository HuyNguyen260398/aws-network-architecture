# =============================================================================
# Container networking.
#
# A container is a process with its own private network namespace: its own
# interfaces, its own addresses, its own ports. This file shows the two ways
# that private network gets connected to everything else.
#
# PART 1 -- a Docker host. Containers sit on a BRIDGE network that exists only
#           inside one host. They find each other by container name, and the
#           outside world reaches them through PORT MAPPING: the host listens
#           on a port and translates the destination to a container.
#
# PART 2 -- Amazon ECS on Fargate, in awsvpc mode. Each task gets its own
#           elastic network interface and a real VPC address. No bridge, no
#           port mapping, no translation: the VPC routes straight to the
#           container, and security groups apply to it like any other host.
# =============================================================================

variable "container_image" {
  description = "Image the shop's containers run. Any image with Python 3 works; the application itself is injected at start. Pulled from the Amazon ECR public gallery to avoid Docker Hub rate limits."
  type        = string
  default     = "public.ecr.aws/docker/library/python:3.13-alpine"
}

variable "enable_docker_host" {
  description = "Run a Docker host in the public subnet with the frontend and payment service as two containers on a user-defined bridge network. One t4g.micro and one public IPv4 address: about USD 0.016/hour."
  type        = bool
  default     = true
}

variable "docker_host_instance_type" {
  description = "Instance type of the Docker host. A t4g.nano's 0.5 GiB is not enough for the Docker daemon plus two containers."
  type        = string
  default     = "t4g.micro"
}

variable "docker_published_port" {
  description = "Port on the Docker HOST that is mapped to port 80 of the frontend container."
  type        = number
  default     = 8080

  validation {
    condition     = var.docker_published_port >= 1024 && var.docker_published_port <= 65535
    error_message = "docker_published_port must be between 1024 and 65535."
  }
}

variable "enable_ecs" {
  description = <<-EOT
    Run the payment service as an ECS service on Fargate with awsvpc networking
    and Cloud Map service discovery.

    COST: roughly USD 0.012/hour per task (0.25 vCPU, 0.5 GiB, ARM), so about
    USD 0.024/hour for the default two replicas, plus a public IPv4 address per
    task when there is no NAT gateway.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_ecs || var.acknowledge_costs
    error_message = "enable_ecs requires acknowledge_costs = true. Two Fargate tasks cost about USD 17/month."
  }
}

variable "ecs_desired_count" {
  description = "How many copies (replicas) of the payment task to run. More than one is what makes service discovery and load balancing necessary: there is no longer a single address to connect to."
  type        = number
  default     = 2

  validation {
    condition     = var.ecs_desired_count >= 1 && var.ecs_desired_count <= 4
    error_message = "ecs_desired_count must be between 1 and 4."
  }
}

variable "service_discovery_namespace" {
  description = "Private DNS namespace for container services. The payment service becomes payment.<namespace>, resolvable only inside the VPC."
  type        = string
  default     = "svc.shop.internal"
}

locals {
  ecs_enabled = var.enable_ecs && var.acknowledge_costs

  # A task has to pull its image before it can start. In the app subnets that
  # needs the NAT gateway; without one, the tasks run in the public subnets
  # with a public address each -- the same trade lab 03 was about.
  ecs_in_private_subnets = local.nat_gateway_mode != "none"
  ecs_subnet_ids = local.ecs_in_private_subnets ? (
    [for key in sort(keys(local.app_subnets)) : module.vpc.private_subnet_ids[key]]
    ) : (
    [for key in sort(keys(local.public_subnets)) : module.vpc.public_subnet_ids[key]]
  )

  ecs_behind_load_balancer = local.ecs_enabled && local.load_balancer_enabled
}

# -----------------------------------------------------------------------------
# PART 1: Docker host -- bridge network, container names, port mapping
# -----------------------------------------------------------------------------
module "docker_apps" {
  source = "../../modules/demo-service"

  # No systemd services: this only drops the application on disk. Docker runs it.
  services = {}
}

locals {
  docker_commands = <<-SH
    dnf install -y docker
    systemctl enable --now docker

    # A user-defined bridge. Unlike the default bridge it has a built-in DNS
    # server, so containers on it resolve each other BY NAME.
    docker network create shop-net

    # The payment container publishes nothing. It is reachable from other
    # containers on shop-net and from nowhere else -- not even from the VPC.
    docker run -d --restart unless-stopped --name payment --network shop-net \
      -v /opt/shop/app.py:/app.py:ro ${var.container_image} \
      python /app.py payment ${local.payment_port}

    # The frontend reaches payment by container name, and is PUBLISHED:
    # host port ${var.docker_published_port} is forwarded to container port ${local.frontend_port}.
    docker run -d --restart unless-stopped --name frontend --network shop-net \
      -p ${var.docker_published_port}:${local.frontend_port} \
      -v /opt/shop/app.py:/app.py:ro ${var.container_image} \
      python /app.py frontend ${local.frontend_port} http://payment:${local.payment_port}/
  SH

  # The application script first, then the Docker setup. Joined rather than
  # nested so the "#!" line stays at the very start of the script.
  docker_user_data = "${module.docker_apps.user_data}\n${local.docker_commands}"
}

module "docker_host" {
  count  = var.enable_docker_host ? 1 : 0
  source = "../../modules/test-instance"

  name   = "${local.name_prefix}-docker"
  vpc_id = module.vpc.vpc_id
  # Public subnet: the host must reach the package repositories and the image
  # registry to set itself up, and this costs nothing extra.
  subnet_id     = module.vpc.public_subnet_ids["public-a"]
  instance_type = var.docker_host_instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  user_data                   = local.docker_user_data
  user_data_replace_on_change = true

  ingress_rules = {
    # The security group sees the HOST port. It knows nothing about containers.
    published_port = {
      description = "Port published by the frontend container"
      ip_protocol = "tcp"
      from_port   = var.docker_published_port
      to_port     = var.docker_published_port
      cidr_ipv4   = var.allowed_client_cidr
    }
    icmp = local.icmp_from_vpc
  }

  tags = merge(local.common_tags, { Tier = "containers" })
}

# -----------------------------------------------------------------------------
# PART 2: ECS on Fargate -- every task is a first-class VPC host
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster" "shop" {
  count = local.ecs_enabled ? 1 : 0

  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = merge(local.common_tags, { Name = local.name_prefix })
}

resource "aws_cloudwatch_log_group" "ecs" {
  count = local.ecs_enabled ? 1 : 0

  name              = "/${local.name_prefix}/ecs"
  retention_in_days = 7

  tags = local.common_tags
}

# Lets ECS pull the image and write logs on the task's behalf. It grants the
# containers themselves nothing.
resource "aws_iam_role" "ecs_execution" {
  count = local.ecs_enabled ? 1 : 0

  name_prefix = "${local.name_prefix}-ecs-exec-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  count = local.ecs_enabled ? 1 : 0

  role       = aws_iam_role.ecs_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "payment" {
  count = local.ecs_enabled ? 1 : 0

  family                   = "${local.name_prefix}-payment"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution[0].arn

  # awsvpc: the task gets its own network interface in the subnet, with its
  # own private address and its own security group.
  network_mode = "awsvpc"

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.instance_architecture == "arm64" ? "ARM64" : "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "payment"
      image     = var.container_image
      essential = true

      # The application is passed in as an environment variable so the lab
      # needs no image build and no registry of its own.
      command = ["sh", "-c", "echo \"$APP_B64\" | base64 -d > /tmp/app.py && exec python /tmp/app.py payment-task ${local.payment_port}"]
      environment = [
        { name = "APP_B64", value = module.docker_apps.app_script_base64 },
      ]

      # Only a container port. In awsvpc mode there is no host port to map it
      # to: the container port IS the port on the task's address.
      portMappings = [
        { containerPort = local.payment_port, protocol = "tcp" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs[0].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "payment"
        }
      }
    },
  ])

  tags = local.common_tags
}

resource "aws_security_group" "ecs_tasks" {
  count = local.ecs_enabled ? 1 : 0

  name_prefix = "${local.name_prefix}-ecs-tasks-"
  description = "Payment tasks: the service port from inside the VPC"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-ecs-tasks" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ecs_tasks_payment" {
  count = local.ecs_enabled ? 1 : 0

  security_group_id = aws_security_group.ecs_tasks[0].id
  description       = "Payment port from inside the VPC"
  ip_protocol       = "tcp"
  from_port         = local.payment_port
  to_port           = local.payment_port
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "ecs_tasks_all" {
  count = local.ecs_enabled ? 1 : 0

  security_group_id = aws_security_group.ecs_tasks[0].id
  description       = "All outbound IPv4: image pull and log delivery"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Service discovery -------------------------------------------------------
# Tasks are replaced constantly and get a new address each time. Nothing can
# depend on a task's address, so clients look the SERVICE up by name instead.
# ECS registers each healthy task here and removes it when it stops.
resource "aws_service_discovery_private_dns_namespace" "shop" {
  count = local.ecs_enabled ? 1 : 0

  name        = var.service_discovery_namespace
  description = "Service discovery for the shop's container services"
  vpc         = module.vpc.vpc_id

  tags = local.common_tags
}

resource "aws_service_discovery_service" "payment" {
  count = local.ecs_enabled ? 1 : 0

  name = "payment"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.shop[0].id

    # One A record per running task; a lookup returns all of them.
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  tags = local.common_tags
}

resource "aws_ecs_service" "payment" {
  count = local.ecs_enabled ? 1 : 0

  name            = "payment"
  cluster         = aws_ecs_cluster.shop[0].id
  task_definition = aws_ecs_task_definition.payment[0].arn
  desired_count   = var.ecs_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.ecs_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks[0].id]
    assign_public_ip = !local.ecs_in_private_subnets
  }

  service_registries {
    registry_arn = aws_service_discovery_service.payment[0].arn
  }

  dynamic "load_balancer" {
    for_each = local.ecs_behind_load_balancer ? [1] : []

    content {
      target_group_arn = aws_lb_target_group.payment_tasks[0].arn
      container_name   = "payment"
      container_port   = local.payment_port
    }
  }

  tags = local.common_tags

  # The target group must be attached to a listener before ECS will use it.
  depends_on = [aws_lb_listener_rule.payment_tasks]
}

# --- Behind the load balancer ------------------------------------------------
# An IP target group: the load balancer sends to task ADDRESSES, which ECS
# registers and deregisters as tasks come and go.
resource "aws_lb_target_group" "payment_tasks" {
  count = local.ecs_behind_load_balancer ? 1 : 0

  name        = "${local.name_prefix}-payment-tasks"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"
  protocol    = "HTTP"
  port        = local.payment_port

  deregistration_delay = 10

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-payment-tasks" })
}

resource "aws_lb_listener_rule" "payment_tasks" {
  count = local.ecs_behind_load_balancer ? 1 : 0

  listener_arn = aws_lb_listener.http[0].arn
  priority     = 5

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.payment_tasks[0].arn
  }

  condition {
    path_pattern {
      values = ["/tasks", "/tasks/*"]
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  count = local.ecs_behind_load_balancer ? 1 : 0

  security_group_id            = aws_security_group.alb[0].id
  description                  = "To the payment tasks"
  ip_protocol                  = "tcp"
  from_port                    = local.payment_port
  to_port                      = local.payment_port
  referenced_security_group_id = aws_security_group.ecs_tasks[0].id
}

output "docker_host_instance_id" {
  description = "Instance ID of the Docker host, or null when disabled."
  value       = one(module.docker_host[*].instance_id)
}

output "docker_frontend_url" {
  description = "The frontend CONTAINER, reached through the port the host publishes for it."
  value       = var.enable_docker_host ? "http://${module.docker_host[0].public_ip}:${var.docker_published_port}/" : null
}

output "ssm_docker_host" {
  description = "Open a shell on the Docker host."
  value       = one(module.docker_host[*].ssm_start_session_command)
}

output "payment_service_dns_name" {
  description = "Name that resolves, inside the VPC, to the address of every running payment task. Null when ECS is disabled."
  value       = local.ecs_enabled ? "payment.${var.service_discovery_namespace}" : null
}

output "verify_containers" {
  description = "Commands for checking container networking. The docker_host_* commands run in a shell on the Docker host; the from_web_* commands in a shell on the web server."
  value = merge(
    var.enable_docker_host ? {
      published_port_from_internet = "curl -s http://${module.docker_host[0].public_ip}:${var.docker_published_port}/"
      payment_not_published        = "curl -s --max-time 5 http://${module.docker_host[0].public_ip}:${local.payment_port}/ || echo 'timed out, as intended'"

      docker_host_bridge_and_addresses = "sudo docker network inspect shop-net --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{println}}{{end}}'"
      docker_host_port_mapping         = "sudo docker port frontend"
      docker_host_name_resolution      = "sudo docker exec frontend python -c \"import socket; print(socket.gethostbyname('payment'))\""
      docker_host_dnat_rule            = "sudo nft list ruleset | grep -i dnat || sudo iptables -t nat -S DOCKER"
    } : {},
    local.ecs_enabled ? {
      task_addresses = "aws ecs describe-tasks --cluster ${aws_ecs_cluster.shop[0].name} --region ${var.aws_region} --tasks $(aws ecs list-tasks --cluster ${aws_ecs_cluster.shop[0].name} --region ${var.aws_region} --query 'taskArns' --output text) --query 'tasks[].{Task:taskArn,IP:attachments[0].details[?name==`privateIPv4Address`]|[0].value,AZ:availabilityZone}' --output table"

      from_web_service_discovery = "dig +short payment.${var.service_discovery_namespace}"
      from_web_call_by_name      = "for i in 1 2 3 4; do curl -s http://payment.${var.service_discovery_namespace}:${local.payment_port}/ | grep -o '\"host\": \"[^\"]*\"'; done"
    } : {},
    local.ecs_behind_load_balancer ? {
      through_load_balancer = "for i in 1 2 3 4; do curl -s http://${aws_lb.shop[0].dns_name}/tasks | grep -o '\"host\": \"[^\"]*\"'; done"
    } : {},
  )
}
