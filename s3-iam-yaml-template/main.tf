terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70.0" # Example: compatible with versions >= 5.0 and < 6.0
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# 🔹 StackSet definition (S3 + IAM role)
resource "aws_cloudformation_stack_set" "s3_iam_stackset" {
  name             = "s3-iam-org-stackset"
  permission_model = "SERVICE_MANAGED"

  auto_deployment {
    enabled                          = true
    retain_stacks_on_account_removal = false
  }

  capabilities = ["CAPABILITY_NAMED_IAM"]

  template_body = <<EOT
AWSTemplateFormatVersion: '2010-09-09'
Description: S3 bucket + IAM role StackSet

Resources:
  MyStackSetBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "stackset-shared-bucket-$${AWS::AccountId}-$${AWS::Region}"

  MyStackSetRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: StackSetDemoRole
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              Service: ec2.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
EOT
}

# 🔹 StackSet instances (deploy to OU but exclude 2 accounts)
# Terraform does NOT support exclusion directly like CLI,
# so you simulate it by explicitly targeting all accounts in the OU except the excluded ones.
variable "has_excluded_accounts" {
  default = false
}

variable "has_no_excluded_accounts" {
  default = true
}

variable "excluded_accounts" {
  default = ["111111111111", "222222222222"]
}

data "aws_organizations_organization" "org" {
    count = 1
}

# Collect all accounts in org
# data "aws_organizations_accounts" "all_accounts" {}

# Filter accounts in target OU
# locals {
#   target_ou_id    = "ou-abcd-12345678"
#   target_accounts = [
#     for a in data.aws_organizations_accounts.all_accounts.accounts :
#     a.id if a.parent_id == local.target_ou_id && !(contains(var.excluded_accounts, a.id))
#   ]
# }

resource "aws_cloudformation_stack_set_instance" "deploy_to_ou_with_excluded_accounts" {
    count = var.has_excluded_accounts ? 1 : 0
  deployment_targets {
    account_filter_type     = "DIFFERENCE"
    accounts                = var.excluded_accounts
    organizational_unit_ids = [data.aws_organizations_organization.org[0].roots[0].id]
  }

  operation_preferences {
    failure_tolerance_count = 24
    max_concurrent_count    = 25
    region_concurrency_type = "PARALLEL"
  }
  stack_set_name = aws_cloudformation_stack_set.s3_iam_stackset.name
  region         = "us-east-1"
}


resource "aws_cloudformation_stack_set_instance" "deploy_to_all_ou_accounts" {
    count = var.has_no_excluded_accounts ? 1 : 0
  deployment_targets {
    organizational_unit_ids = [data.aws_organizations_organization.org[0].roots[0].id]
  }

  operation_preferences {
    failure_tolerance_count = 24
    max_concurrent_count    = 25
    region_concurrency_type = "PARALLEL"
  }
  stack_set_name = aws_cloudformation_stack_set.s3_iam_stackset.name
  region         = "us-east-1"
}