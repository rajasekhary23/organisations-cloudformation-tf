# CloudFormation Stack, StackSet, and StackSetInstance — Practical Guide

This guide explains the differences between **Stacks**, **StackSets**, and **StackSet Instances**, shows how to auto-deploy resources (like S3 + IAM) across AWS accounts in an OU, how to exclude accounts, and how to run both **CloudFormation (CLI)** and **Terraform** implementations.

---

## 🔹 Key Concepts

### 1. CloudFormation Stack
- A single deployment of a CloudFormation template in **one account + one region**.
- Example: Deploying a single S3 bucket.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Simple S3 Bucket Stack

Resources:
  MySimpleBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "my-simple-bucket-${AWS::AccountId}-${AWS::Region}"
```
Run:
```yaml
aws cloudformation create-stack \
  --stack-name simple-s3-stack \
  --template-body file://s3-bucket.yaml \
  --capabilities CAPABILITY_NAMED_IAM
```

### 2. CloudFormation StackSet
A collection of stacks that can be deployed across multiple accounts and regions.
Useful for rolling out standard resources (S3 buckets, IAM roles, security controls) org-wide.
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Simple StackSet for S3 bucket

Resources:
  MyStackSetBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "stackset-bucket-${AWS::AccountId}-${AWS::Region}"
```
Create StackSet:
```yaml
aws cloudformation create-stack-set \
  --stack-set-name simple-s3-stackset \
  --template-body file://s3-stackset.yaml \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
  --capabilities CAPABILITY_NAMED_IAM
```

### 3. CloudFormation StackSet Instance
Represents an actual deployment target for the StackSet (to accounts or OUs).
Example: Deploy to an OU but exclude specific accounts.
```yaml
aws cloudformation create-stack-instances \
  --stack-set-name s3-iam-org-stackset \
  --deployment-targets OrganizationalUnitIds=ou-abcd-12345678 \
  --regions us-east-1 \
  --accounts 111111111111 222222222222 \
  --account-filter-type DIFFERENCE \
  --operation-preferences FailureToleranceCount=0 MaxConcurrentCount=5
```
## 🔹 Important Properties
`--permission-model`

* `SELF_MANAGED` → You manually create IAM roles in target accounts.

* `SERVICE_MANAGED` → CloudFormation + AWS Organizations handle cross-account IAM automatically. Required for auto-deployment to new accounts.

`--capabilities`

* `CAPABILITY_IAM` → Allows creation of IAM resources with system-generated names.

* `CAPABILITY_NAMED_IAM` → Allows creation of IAM resources with custom names.

`--operation-preferences`

Controls rollout strategy:

* `FailureToleranceCount=0` → Fail immediately if 1 account fails.
* `MaxConcurrentCount=5` → Deploy to 5 accounts at a time.
* `FailureTolerancePercentage=5` → Allow 5% of accounts to fail.
* `MaxConcurrentPercentage=20` → Deploy to 20% of accounts in parallel.
* `RegionConcurrencyType=SEQUENTIAL` → Safer rollout, one region at a time.

## 🔹 Best practice for 100+ accounts:
```yaml
--operation-preferences \
  FailureTolerancePercentage=5 \
  MaxConcurrentPercentage=20 \
  RegionConcurrencyType=SEQUENTIAL
```
🔹 Example: Deploying S3 + IAM Role with Exclusions (CloudFormation)

`s3-iam-stackset.yaml`:
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: S3 bucket + IAM role StackSet

Resources:
  MyStackSetBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "stackset-shared-bucket-${AWS::AccountId}-${AWS::Region}"

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
```
Run:
```yaml
# 1. Create the StackSet
aws cloudformation create-stack-set \
  --stack-set-name s3-iam-org-stackset \
  --template-body file://s3-iam-stackset.yaml \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
  --capabilities CAPABILITY_NAMED_IAM

# 2. Deploy to OU, excluding 2 accounts
aws cloudformation create-stack-instances \
  --stack-set-name s3-iam-org-stackset \
  --deployment-targets OrganizationalUnitIds=ou-abcd-12345678 \
  --regions us-east-1 \
  --accounts 111111111111 222222222222 \
  --account-filter-type DIFFERENCE \
  --operation-preferences FailureToleranceCount=0 MaxConcurrentCount=5
```
🔹 Terraform Equivalent with Exclusions

Terraform uses aws_cloudformation_stack_set and aws_cloudformation_stack_set_instance.
Exclusions are done by filtering accounts.
```yaml
provider "aws" {
  region = "us-east-1"
}

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
      BucketName: !Sub "stackset-shared-bucket-${AWS::AccountId}-${AWS::Region}"

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

variable "excluded_accounts" {
  default = ["111111111111", "222222222222"]
}

data "aws_organizations_organization" "org" {}
data "aws_organizations_accounts" "all_accounts" {}

locals {
  target_ou_id    = "ou-abcd-12345678"
  target_accounts = [
    for a in data.aws_organizations_accounts.all_accounts.accounts :
    a.id if a.parent_id == local.target_ou_id && !(contains(var.excluded_accounts, a.id))
  ]
}

resource "aws_cloudformation_stack_set_instance" "deploy_to_accounts" {
  for_each        = toset(local.target_accounts)
  stack_set_name  = aws_cloudformation_stack_set.s3_iam_stackset.name
  account_id      = each.value
  region          = "us-east-1"
}
```
Run:
```yaml
terraform init
terraform plan
terraform apply
```

✅ Summary

**Stack** → one account + one region.

**StackSet** → reusable template for multi-account + multi-region.

**StackSet Instance** → actual deployment target.

Use `SERVICE_MANAGED` for org-wide automation.

Use `CAPABILITY_NAMED_IAM` if creating IAM roles/policies with custom names.

Use `--account-filter-type DIFFERENCE` (CLI) or filtering in Terraform to exclude accounts.

Always tune `--operation-preferences` for large orgs to avoid throttling.

### **Terraform thinks ${AWS::AccountId} is its own interpolation.**

✅ Fix: Escape ${} for CloudFormation

In Terraform, if you want literal ${...} to pass through, you need to escape it with $${...}.

So update that bucket line to:
```yaml
BucketName: !Sub "stackset-shared-bucket-$${AWS::AccountId}-$${AWS::Region}"
```
```json
"BucketName": {
    "Fn::Sub": "stackset-shared-bucket-$${AWS::AccountId}-$${AWS::Region}"
}
```
⚡ Now when you run terraform apply, Terraform won’t try to interpolate those values and will pass them correctly to CloudFormation.
✅ Recommendation
* If you’re using Terraform + template_body inline → prefer JSON to avoid escaping headaches.
* For bigger templates → store YAML/JSON in a separate file and use template_url (S3 upload), which avoids interpolation issues entirely.

### ⚡Debugging point 👌 — this error means Terraform successfully created the StackSet, but the StackSetInstance creation failed when CloudFormation tried to roll it out into accounts.

The error message: 
```perl
unexpected state 'FAILED', wanted target 'SUCCEEDED'
```
is generic — the **real cause** is hidden in the **StackSet operation status**.
### 🔹 Step 1: Check StackSet Operation Status

Run this to see why it failed:
```yaml
aws cloudformation describe-stack-set-operation \
  --stack-set-name s3-iam-org-stackset \
  --operation-id $(aws cloudformation list-stack-set-operations --stack-set-name s3-iam-org-stackset --query "Summaries[0].OperationId" --output text)
```

This will tell you if it failed due to:

* IAM permissions
* Account not part of OU
* Service-managed vs self-managed roles
* Region mismatch
* Duplicate S3 bucket names

### 🔹 Step 2: Common Root Causes
#### 1. S3 Bucket Naming Conflict

S3 bucket names must be **globally unique**.
If another account/region already created:

```json
"BucketName": "stackset-shared-bucket-111111111111-us-east-1"
```


and you re-run, the stack will fail.

👉 Fix: Add randomness to bucket name:
```json
"BucketName": { "Fn::Sub": "stackset-shared-bucket-${AWS::AccountId}-$${AWS::Region}-$${AWS::StackName}" }
```
#### 2. IAM Role Creation Conflict

If RoleName: StackSetDemoRole already exists in an account, stack creation fails.

👉 Fix: Let CloudFormation generate the name (remove RoleName) or add randomness:
```json
"RoleName": { "Fn::Sub": "StackSetDemoRole-$${AWS::Region}" }
```
#### 3. Permission Model Mismatch

If you used:
```hcl
permission_model = "SERVICE_MANAGED"
```

then:

Your AWS Organization must have trusted access enabled for CloudFormation StackSets.

Run this if not already done:
```bash
aws organizations enable-aws-service-access --service-principal stacksets.cloudformation.amazonaws.com

aws cloudformation enable-organization-access
```
#### 4. OU Filtering Issue

In the Terraform example we filtered accounts from OU.
If the OU ID is wrong, or accounts are suspended, the StackSetInstance will fail.

👉 Verify OU & account list:
```bash
aws organizations list-accounts-for-parent --parent-id ou-abcd-12345678
```
#### 5. Region Issue

If you specified a region where StackSets is not enabled, the instance creation fails.
Make sure you deploy to at least 1 supported region (e.g., us-east-1).

### 🔹 Step 3: Debug in CloudFormation Console

* Go to AWS **Console** → **CloudFormation** → **StackSets** → **Operations**.

* Click on the failed operation → expand the failed account → see the exact error message.

That message will directly tell you whether it’s:
❌ “Bucket already exists”
❌ “Role already exists”
❌ “Access Denied”

✅ Fix summary:

1. Check operation failure reason (describe-stack-set-operation).

2. Ensure trusted access for SERVICE_MANAGED.

3. Make S3 bucket & IAM role names unique per account/region.

4. Double-check OU ID & excluded accounts.

5. Deploy only to supported regions.