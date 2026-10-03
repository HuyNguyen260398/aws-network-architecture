# =============================================================================
# Kubernetes networking.
#
# The same shop, on Amazon EKS. Terraform builds the cluster and the network
# around it; the workloads are plain Kubernetes manifests (k8s/shop.yaml.tftpl)
# that you apply with kubectl, so you can read and change them directly.
#
# What the VPC contributes:
#
#   pod IPs    EKS uses the VPC CNI. Every pod gets a real address from the
#              subnet its node is in -- no overlay network, no translation.
#   nodes      EKS Auto Mode launches and retires them in the app subnets.
#   ingress    Auto Mode creates an Application Load Balancer in the public
#              subnets and points it straight at pod addresses.
#
# Service addresses (kubernetes_service_cidr) are the one range here that is
# NOT in the VPC: they are virtual, and exist only inside the cluster.
# =============================================================================

variable "enable_eks" {
  description = <<-EOT
    Create an EKS cluster in Auto Mode.

    COST: the control plane alone is USD 0.10/hour (about USD 73/month). Nodes
    are EC2 instances plus the Auto Mode management fee, and the Ingress adds
    an Application Load Balancer: expect roughly USD 0.20-0.25/hour in total
    while the shop is deployed. Destroy it when you finish the lab.

    Requires enable_nat_gateway: nodes run in the private app subnets and must
    pull container images.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_eks || var.acknowledge_costs
    error_message = "enable_eks requires acknowledge_costs = true. An EKS cluster costs at least USD 73/month before any nodes."
  }

  validation {
    condition     = !var.enable_eks || var.enable_nat_gateway
    error_message = "enable_eks requires enable_nat_gateway = true. EKS nodes run in the private app subnets and need an outbound path to pull images."
  }
}

variable "eks_api_allowed_cidr" {
  description = "IPv4 range allowed to reach the cluster's public API endpoint -- where kubectl connects. Narrow it to your own address as a /32."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.eks_api_allowed_cidr, 0))
    error_message = "eks_api_allowed_cidr must be a valid IPv4 CIDR."
  }
}

variable "kubernetes_service_cidr" {
  description = "Range for Kubernetes Service addresses. Virtual: it is never routed in the VPC, so it must not overlap the VPC or anything the VPC will be connected to in later labs."
  type        = string
  default     = "172.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.kubernetes_service_cidr, 0))
    error_message = "kubernetes_service_cidr must be a valid IPv4 CIDR."
  }
}

locals {
  eks_enabled = var.enable_eks && var.acknowledge_costs && var.enable_nat_gateway

  eks_cluster_policies = [
    "AmazonEKSClusterPolicy",
    "AmazonEKSComputePolicy",
    "AmazonEKSBlockStoragePolicy",
    "AmazonEKSLoadBalancingPolicy",
    "AmazonEKSNetworkingPolicy",
  ]

  eks_node_policies = [
    "AmazonEKSWorkerNodeMinimalPolicy",
    "AmazonEC2ContainerRegistryPullOnly",
  ]
}

resource "aws_iam_role" "eks_cluster" {
  count = local.eks_enabled ? 1 : 0

  name_prefix = "${local.name_prefix}-eks-cluster-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["sts:AssumeRole", "sts:TagSession"]
        Principal = { Service = "eks.amazonaws.com" }
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  for_each = local.eks_enabled ? toset(local.eks_cluster_policies) : toset([])

  role       = aws_iam_role.eks_cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

resource "aws_iam_role" "eks_node" {
  count = local.eks_enabled ? 1 : 0

  name_prefix = "${local.name_prefix}-eks-node-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ec2.amazonaws.com" }
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = local.eks_enabled ? toset(local.eks_node_policies) : toset([])

  role       = aws_iam_role.eks_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

resource "aws_eks_cluster" "shop" {
  count = local.eks_enabled ? 1 : 0

  name     = local.name_prefix
  role_arn = aws_iam_role.eks_cluster[0].arn

  # Auto Mode supplies its own networking, storage and load balancing
  # components, so the self-managed add-ons are not installed.
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode = "API"
    # Whoever runs `terraform apply` becomes cluster admin, so kubectl works.
    bootstrap_cluster_creator_admin_permissions = true
  }

  compute_config {
    enabled       = true
    node_pools    = ["general-purpose", "system"]
    node_role_arn = aws_iam_role.eks_node[0].arn
  }

  kubernetes_network_config {
    service_ipv4_cidr = var.kubernetes_service_cidr

    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  vpc_config {
    # Nodes -- and therefore pods -- live in the app subnets, one per zone.
    subnet_ids = [for key in sort(keys(local.app_subnets)) : module.vpc.private_subnet_ids[key]]

    # kubectl reaches the API over the internet; nodes reach it privately.
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = [var.eks_api_allowed_cidr]
  }

  tags = merge(local.common_tags, { Name = local.name_prefix })

  # The cluster cannot create or clean up its network interfaces and load
  # balancers without these, so they must outlive it on destroy.
  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster, or null when disabled."
  value       = one(aws_eks_cluster.shop[*].name)
}

output "kubeconfig_command" {
  description = "Writes a kubeconfig entry for the cluster so kubectl can reach it."
  value       = local.eks_enabled ? "aws eks update-kubeconfig --name ${aws_eks_cluster.shop[0].name} --region ${var.aws_region}" : null
}

output "k8s_manifest" {
  description = "The shop's Kubernetes manifest. Pipe it to kubectl: terraform output -raw k8s_manifest | kubectl apply -f -"
  value = templatefile("${path.module}/k8s/shop.yaml.tftpl", {
    app_script        = trimspace(module.docker_apps.app_script)
    image             = var.container_image
    payment_port      = local.payment_port
    public_subnet_ids = [for key in sort(keys(local.public_subnets)) : module.vpc.public_subnet_ids[key]]
  })
}

output "verify_kubernetes" {
  description = "kubectl commands for checking Kubernetes networking. Empty when the cluster is disabled."
  value = local.eks_enabled ? {
    pod_addresses_are_vpc_addresses = "kubectl -n shop get pods -o wide"
    node_addresses                  = "kubectl get nodes -o wide"
    services_have_virtual_addresses = "kubectl -n shop get services"
    endpoints_behind_each_service   = "kubectl -n shop get endpointslices"
    ingress_address                 = "kubectl -n shop get ingress shop"

    call_service_by_name = "kubectl -n shop exec deploy/frontend -- python -c \"import urllib.request; print(urllib.request.urlopen('http://payment:${local.payment_port}/').read().decode())\""
    path_rule            = "curl -s http://$(kubectl -n shop get ingress shop -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/pay"
    host_rule            = "curl -s -H 'Host: pay.shop.test' http://$(kubectl -n shop get ingress shop -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/"
  } : {}
}
