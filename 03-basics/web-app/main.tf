# This Terraform configuration is used to provision infrastructure on AWS.

terraform {
  # Configuration for the Terraform backend.
  # This is where Terraform stores its state file.
  backend "s3" {
    bucket         = "devops-directive-tf-state" # The S3 bucket name where the state file is stored.
    key            = "03-basics/web-app/terraform.tfstate" # Path to the state file within the bucket.
    region         = "us-east-1" # AWS region where the bucket is located.
    dynamodb_table = "terraform-state-locking" # DynamoDB table for state locking and consistency.
    encrypt        = true # Ensures the state file is encrypted at rest.
  }

  # Specifies the required providers and their versions.
  required_providers {
    aws = {
      source  = "hashicorp/aws" # The source of the AWS provider.
      version = "~> 3.0" # The version of the AWS provider.
    }
  }
}

# Provider block configures the specified provider, in this case, AWS.
provider "aws" {
  region = "us-east-1" # The region where AWS resources will be created.
}

# Resource block for creating an AWS EC2 instance.
resource "aws_instance" "instance_1" {
  ami             = "ami-011899242bb902164" # AMI ID for Ubuntu 20.04 LTS in us-east-1.
  instance_type   = "t2.micro" # The type of instance to start.
  security_groups = [aws_security_group.instances.name] # Associates the instance with a security group.
  # User data to be executed at launch. Here, it starts a simple HTTP server.
  user_data       = <<-EOF
              #!/bin/bash
              echo "Hello, World 1" > index.html
              python3 -m http.server 8080 &
              EOF
}

# Similar to the first instance, but serves "Hello, World 2".
resource "aws_instance" "instance_2" {
  ami             = "ami-011899242bb902164"
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.instances.name]
  user_data       = <<-EOF
              #!/bin/bash
              echo "Hello, World 2" > index.html
              python3 -m http.server 8080 &
              EOF
}

# Creates an S3 bucket with a unique name prefix.
resource "aws_s3_bucket" "bucket" {
  bucket_prefix = "devops-directive-web-app-data"
  force_destroy = true # Allows the bucket to be destroyed even if it contains objects.
}

# Enables versioning on the S3 bucket.
resource "aws_s3_bucket_versioning" "bucket_versioning" {
  bucket = aws_s3_bucket.bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Configures server-side encryption for the S3 bucket.
resource "aws_s3_bucket_server_side_encryption_configuration" "bucket_crypto_conf" {
  bucket = aws_s3_bucket.bucket.bucket
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Retrieves the default VPC.
data "aws_vpc" "default_vpc" {
  default = true
}

# Retrieves subnet IDs for the default VPC.
data "aws_subnet_ids" "default_subnet" {
  vpc_id = data.aws_vpc.default_vpc.id
}

# Creates a security group for the instances.
resource "aws_security_group" "instances" {
  name = "instance-security-group"
}

# Allows inbound HTTP traffic to the instances.
resource "aws_security_group_rule" "allow_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.instances.id
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Configuration for an AWS Load Balancer (ALB) listener.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.load_balancer.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

# Target group for the instances.
resource "aws_lb_target_group" "instances" {
  name     = "example-target-group"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default_vpc.id
  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Attaches instance 1 to the target group.
resource "aws_lb_target_group_attachment" "instance_1" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_1.id
  port             = 8080
}

# Attaches instance 2 to the target group.
resource "aws_lb_target_group_attachment" "instance_2" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_2.id
  port             = 8080
}

# Listener rule for the ALB to forward requests to the target group.
resource "aws_lb_listener_rule" "instances" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100
  condition {
    path_pattern {
      values = ["*"]
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.instances.arn
  }
}

# Security group for the ALB.
resource "aws_security_group" "alb" {
  name = "alb-security-group"
}

# Allows inbound HTTP traffic to the ALB.
resource "aws_security_group_rule" "allow_alb_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Allows all outbound traffic from the ALB.
resource "aws_security_group_rule" "allow_alb_all_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Creates the ALB.
resource "aws_lb" "load_balancer" {
  name               = "web-app-lb"
  load_balancer_type = "application"
  subnets            = data.aws_subnet_ids.default_subnet.ids
  security_groups    = [aws_security_group.alb.id]
}

# Creates a Route 53 zone.
resource "aws_route53_zone" "primary" {
  name = "devopsdeployed.com"
}

# Creates a Route 53 record for the root domain.
resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "devopsdeployed.com"
  type    = "A"
  alias {
    name                   = aws_lb.load_balancer.dns_name
    zone_id                = aws_lb.load_balancer.zone_id
    evaluate_target_health = true
  }
}

# Creates an AWS RDS database instance.
resource "aws_db_instance" "db_instance" {
  allocated_storage           = 20
  auto_minor_version_upgrade  = true
  storage_type                = "standard"
  engine                      = "postgres"
  engine_version              = "12"
  instance_class              = "db.t2.micro"
  name                        = "mydb"
  username                    = "foo"
  password                    = "foobarbaz"
  skip_final_snapshot         = true # Skips the final snapshot before deletion. Not recommended for production.
}