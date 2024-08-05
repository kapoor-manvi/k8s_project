provider "aws" {
  region = local.region
}

provider "random" {
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}

locals {
  name   = "external-secrets"
  region = "us-west-2"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  namespace                = "external-secrets"
  cluster_secretstore_name = "cluster-secretstore-sm"
  cluster_secretstore_sa   = "cluster-secretstore-sa"
  secretstore_name         = "secretstore-ps"
  secretstore_sa           = "secretstore-sa"

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name                   = local.name
  cluster_version                = "1.30"
  cluster_endpoint_public_access = true

  # Give the Terraform identity admin access to the cluster
  # which will allow resources to be deployed into the cluster
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    initial = {
      instance_types = ["t3.medium"]

      min_size     = 1
      max_size     = 5
      desired_size = 2
    }
  }

  tags = local.tags
}

################################################################################
# EKS Blueprints Addons
################################################################################

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # EKS Add-ons
  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns    = {}
    vpc-cni    = {}
    kube-proxy = {}
  }

  # Add-ons
  enable_external_secrets = true

  tags = local.tags
}

#---------------------------------------------------------------
# Supporting Resources
#---------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

resource "aws_kms_key" "secrets" {
  enable_key_rotation = true
}

resource "kubectl_manifest" "cluster_secretstore" {
  yaml_body = <<YAML
    apiVersion: external-secrets.io/v1beta1
    kind: ClusterSecretStore
    metadata:
      name: ${local.cluster_secretstore_name}
    spec:
      provider:
        aws:
          service: SecretsManager
          region: ${local.region}
          auth:
            jwt:
              serviceAccountRef:
                name: ${local.cluster_secretstore_sa}
                namespace: ${local.namespace}
  YAML

  depends_on = [module.eks_blueprints_addons]
}

resource "aws_secretsmanager_secret" "secret" {
  name = "RdsAdminCred"
  recovery_window_in_days = 0
  kms_key_id              = aws_kms_key.secrets.arn
}

resource "random_password" "master_password" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret_version" "secret" {
  secret_id = aws_secretsmanager_secret.secret.id
  secret_string = jsonencode({
    username = "secretuser",
    password = "${random_password.master_password.result}"
  })
}

data "aws_secretsmanager_secret" "secret" {
  name = "RdsAdminCred"
  depends_on = [
    aws_secretsmanager_secret.secret ]
}

data "aws_secretsmanager_secret_version" "secret" {
  secret_id = data.aws_secretsmanager_secret.secret.id
}

resource "kubectl_manifest" "secret" {
  yaml_body = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: ${local.name}-sm
      namespace: ${local.namespace}
    spec:
      refreshInterval: 1h
      secretStoreRef:
        name: ${local.cluster_secretstore_name}
        kind: ClusterSecretStore
      dataFrom:
      - extract:
          key: ${aws_secretsmanager_secret.secret.name}
  YAML

  depends_on = [kubectl_manifest.cluster_secretstore]
}

# IRSA
#---------------------------------------------------------------

module "cluster_secretstore_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${module.eks.cluster_name}-secrets-manager-"

  role_policy_arns = {
    policy = aws_iam_policy.cluster_secretstore.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.namespace}:${local.cluster_secretstore_sa}"]
    }
  }

  tags = local.tags
}

resource "aws_iam_policy" "cluster_secretstore" {
  name_prefix = local.cluster_secretstore_sa
  policy      = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds"
      ],
      "Resource": "${aws_secretsmanager_secret.secret.arn}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt"
      ],
      "Resource": "${aws_kms_key.secrets.arn}"
    }
  ]
}
POLICY
}


module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${module.eks.cluster_name}-ebs-csi-driver-"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}


# resource "aws_db_instance" "mydb" {
#   allocated_storage    = 20
#   engine_version = "16.3"
#   db_name = "transactiondb"
#   storage_type         = "gp3"
#   engine               = "postgres"
#   instance_class       = "db.t3.micro"
#   username             = jsondecode(data.aws_secretsmanager_secret_version.secret.secret_string)["username"]
#   password             = jsondecode(data.aws_secretsmanager_secret_version.secret.secret_string)["password"]
#   skip_final_snapshot  = true
#   publicly_accessible  = false

#   vpc_security_group_ids = [aws_security_group.rds.id]
#   db_subnet_group_name   = aws_db_subnet_group.main.name
# }

# resource "aws_db_subnet_group" "main" {
#   name       = "main-subnet-group"
#   subnet_ids = module.vpc.private_subnets
# }

# resource "aws_security_group" "rds" {
#   vpc_id = module.vpc.vpc_id

#   ingress {
#     from_port   = 5432
#     to_port     = 5432
#     protocol    = "tcp"
#     security_groups = [module.eks.node_security_group_id]
#   }

#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
# }
