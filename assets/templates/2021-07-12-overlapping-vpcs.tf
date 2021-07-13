terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
  }

  required_version = ">= 0.14.9"
}

provider "aws" {
  profile = "default"
  region  = "us-east-2"
  default_tags {
    tags = {
      terraform = "true"
    }
  }
}

# Get the latest AL2 AMI via SSM

data "aws_ssm_parameter" "amzn2_ami" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

# Define resources

module "tgw" {
  source  = "terraform-aws-modules/transit-gateway/aws"
  version = "~> 2.0"

  name        = "tgw-overlap-demo"
  description = "TGW for connecting overlapping VPCs (demo)"

  enable_auto_accept_shared_attachments  = false
  enable_default_route_table_association = false
  enable_default_route_table_propagation = false
  share_tgw                              = false
}

module "overlap_vpc_1" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = "Overlapping VPC 1"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-2a", "us-east-2b"]
  public_subnets  = ["10.0.1.0/24"]
  private_subnets = ["10.0.2.0/24"]
}

module "overlap_vpc_2" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = "Overlapping VPC 2"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-2a", "us-east-2b"]
  public_subnets  = ["10.0.1.0/24"]
  private_subnets = ["10.0.2.0/24"]
}

module "security_group_1" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "4.3.0"

  name        = "example"
  description = "Security group for overlapping VPCs"
  vpc_id      = module.overlap_vpc_1.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["http-80-tcp", "all-icmp", "ssh-tcp"]
  egress_rules        = ["all-all"]
}

module "security_group_2" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "4.3.0"

  name        = "example"
  description = "Security group for overlapping VPCs"
  vpc_id      = module.overlap_vpc_2.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["http-80-tcp", "all-icmp", "ssh-tcp"]
  egress_rules        = ["all-all"]
}


module "ec2_instance_1" {
  source = "terraform-aws-modules/ec2-instance/aws"

  name                   = "Overlapping Instance 1"
  ami                    = data.aws_ssm_parameter.amzn2_ami.value
  instance_type          = "t2.micro"
  subnet_id              = module.overlap_vpc_1.public_subnets[0]
  vpc_security_group_ids = [module.security_group_1.security_group_id]
  user_data              = <<-EOF
    #!/bin/bash
    yum update -y
    yum install httpd -y
    systemctl enable --now httpd
    echo "Hello from Instance 1" | sudo tee /var/www/html/index.html
  EOF
  tags = {
    Name = "Overlapping Instance 1"
  }
}

module "ec2_instance_2" {
  source = "terraform-aws-modules/ec2-instance/aws"

  name                   = "Overlapping Instance 2"
  ami                    = data.aws_ssm_parameter.amzn2_ami.value
  instance_type          = "t2.micro"
  subnet_id              = module.overlap_vpc_2.public_subnets[0]
  vpc_security_group_ids = [module.security_group_2.security_group_id]
  user_data              = <<-EOF
    #!/bin/bash
    yum update -y
    yum install httpd -y
    systemctl enable --now httpd
    echo "Hello from Instance 2" | sudo tee /var/www/html/index.html
  EOF
  tags = {
    Name = "Overlapping Instance 2"
  }
}
