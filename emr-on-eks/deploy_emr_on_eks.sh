#!/bin/bash
set -euo pipefail

# =====================================================================================
# This script creates an S3 bucket, uploads CloudFormation templates, executes the
# main stack, waits, and then executes few additional scripts.
#
# Key functionalities include:
# - Setting up an S3 bucket
# - Uploading CloudFormation templates
# - Executing the main CloudFormation stack
# - Setup EKS Clusters
# - Setup EMR on EKS Clusters
#
# To delete resources, use:
# ./cleanup.sh
# =====================================================================================

# Constants
BUCKET_NAME_PREFIX="spark-history-server-cfn-templates"
S3_KEY_PREFIX="emr-on-eks"
MAIN_STACK_NAME="SHS-EMROnEKSStack"
MAIN_TEMPLATE_FILE="main-stack.yaml"
TEMPLATE_FILES=(
    "main-stack.yaml"
    "eks-stack.yaml"
    "emr-on-eks-stack.yaml"
)

# Resource names created by the Infra stack
INFRA_STACK_NAME="SHS-BaseInfraStack"
INFRA_VPC_NAME="${INFRA_STACK_NAME}-VPC"

# Scripts
EKS_CONFIGURE_SCRIPT="eks/configure_eks_cluster.sh"
EMR_EKS_SCRIPT="emr-on-eks/configure_emr_on_eks.sh"

# EKS Clusters
DATA_SCIENCE_CLUSTER="datascience-cluster"
ANALYTICS_CLUSTER="analytics-cluster"

# List of EKS Cluster
DATA_PROCESSING_CLUSTERS=(
    $DATA_SCIENCE_CLUSTER
    $ANALYTICS_CLUSTER
)

# Global Variables
AWS_ACCOUNT_ID=""
S3_BUCKET_NAME=""

# Networking 
VPC_ID=""
PUBLIC_SUBNETS=""
PRIVATE_SUBNETS=""

# OIDC Providers
ANALYTICS_CLUSTER_OIDC_PROVIDER=""
DATASCIENCE_CLUSTER_OIDC_PROVIDER=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "This script sets up an S3 bucket, uploads CFN templates, deploys the main stack, and runs additional scripts."
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region to create resources in"
    echo "  REPO_DIR      The directory containing the CloudFormation templates and scripts"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  export REPO_DIR=/path/to/blog/directory"
    echo "  ./$(basename "$0")"
    exit 1
}

# Get Account Id
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    log "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Get OIDC Provider URL for EKS cluster
get_oidc_provider() {
    local cluster_name=$1
    OIDC_PROVIDER=$(aws eks describe-cluster \
        --name "$cluster_name" \
        --query "cluster.identity.oidc.issuer" \
        --output text | sed 's|https://||')
    echo "$OIDC_PROVIDER"
}


# Setup S3 bucket
setup_s3_bucket() {
    S3_BUCKET_NAME="${BUCKET_NAME_PREFIX}-${AWS_ACCOUNT_ID}-${AWS_REGION}"
    log "Setting up S3 bucket: ${S3_BUCKET_NAME}..."
    
    if ! aws s3api head-bucket --bucket "${S3_BUCKET_NAME}" 2>/dev/null; then
        if [[ $AWS_REGION != "us-east-1" ]]; then
            aws s3api create-bucket \
                --bucket "${S3_BUCKET_NAME}" \
                --region "${AWS_REGION}" \
                --create-bucket-configuration LocationConstraint="${AWS_REGION}" || { log "Error: Failed to create S3 bucket ${S3_BUCKET_NAME}."; return 1; }
        else
            aws s3api create-bucket \
                --bucket "${S3_BUCKET_NAME}" \
                --region "${AWS_REGION}" || { log "Error: Failed to create S3 bucket ${S3_BUCKET_NAME}."; return 1; }
        fi
        log "Created S3 bucket: ${S3_BUCKET_NAME}"
    else
        log "S3 bucket ${S3_BUCKET_NAME} already exists"
    fi

    # Enable default encryption
    aws s3api put-bucket-encryption \
        --bucket "${S3_BUCKET_NAME}" \
        --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}' || { log "Error: Failed to enable encryption for ${S3_BUCKET_NAME}."; return 1; }
    log "Enabled default encryption on S3 bucket: ${S3_BUCKET_NAME}"
}

# Upload templates
upload_templates() {
    log "Uploading CloudFormation templates..."
    for template in "${TEMPLATE_FILES[@]}"; do
        aws s3 cp "./cloudformation/${template}" "s3://${S3_BUCKET_NAME}/cloudformation/${S3_KEY_PREFIX}/" || { log "Error: Failed to upload ${template}."; return 1; }
        log "Uploaded ${template}"
    done
    log "All templates uploaded successfully"
}


# Network details
get_network_details() {
    # VPC
    VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=$INFRA_VPC_NAME " \
    --query "Vpcs[0].VpcId" \
    --output text)

    if [ -z "$VPC_ID" ]; then
        log "Error: Failed to get the VPC_ID"
        return 1
    fi

    # Public Subnet
    PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
        --filters \
            "Name=vpc-id,Values=$VPC_ID" \
            "Name=tag:Name,Values=*Public*" \
        --query "Subnets[].SubnetId" \
        --output text | tr '\t' ',')

    if [ -z "$PUBLIC_SUBNETS" ]; then
        log "Error: Failed to get the PUBLIC_SUBNETS"
        return 1
    fi

    # Private Subnet
    PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters \
        "Name=vpc-id,Values=$VPC_ID" \
        "Name=tag:Name,Values=*Private*" \
    --query "Subnets[].SubnetId" \
    --output text | tr '\t' ',')

    if [ -z "$PRIVATE_SUBNETS" ]; then
        log "Error: Failed to get the PRIVATE_SUBNETS"
        return 1
    fi

    log "Successfully retrieved stack outputs:"
    log "VPC ID: $VPC_ID"
    log "Public Subnets: $PUBLIC_SUBNETS"
    log "Private Subnets: $PRIVATE_SUBNETS"
}

# Create parameters.json
create_parameter_json() {
    # Create parameters.json
    jq --arg vpc_id "$VPC_ID" \
       --arg private_subnets "$PRIVATE_SUBNETS" \
       --arg s3_bucket_name "$S3_BUCKET_NAME" \
       --arg s3_key_prefix "$S3_KEY_PREFIX" \
       '(.[] | select(.ParameterKey == "VPC").ParameterValue) |= $vpc_id |
        (.[] | select(.ParameterKey == "PrivateSubnets").ParameterValue) |= $private_subnets |
        (.[] | select(.ParameterKey == "CfnTemplatesBucketName").ParameterValue) |= $s3_bucket_name |
        (.[] | select(.ParameterKey == "CfnTemplateKeyPrefixName").ParameterValue) |= $s3_key_prefix' \
       "${REPO_DIR}/emr-on-eks/cloudformation/parameters.tpl" > "${REPO_DIR}/emr-on-eks/cloudformation/parameters.json"

    log "Generated parameters.json with:"
    log "VPC ID: $VPC_ID"
    log "Private Subnets: $PRIVATE_SUBNETS"
    log "S3 Bucket Name: $S3_BUCKET_NAME"
    log "S3 Key Prefix: $S3_KEY_PREFIX"
}

# Deploy main stack
deploy_main_stack() {
    log "Deploying main CloudFormation stack..."
    
    if aws cloudformation describe-stacks --stack-name "${MAIN_STACK_NAME}" >/dev/null 2>&1; then
        aws cloudformation update-stack \
            --stack-name "${MAIN_STACK_NAME}" \
            --disable-rollback \
            --template-url "https://${S3_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/cloudformation/${S3_KEY_PREFIX}/${MAIN_TEMPLATE_FILE}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameters file://"${REPO_DIR}/emr-on-eks/cloudformation/parameters.json" || { log "Error: Failed to update main stack."; return 1; }
        log "Updating main stack: ${MAIN_STACK_NAME}"
    else
        aws cloudformation create-stack \
            --stack-name "${MAIN_STACK_NAME}" \
            --disable-rollback \
            --template-url "https://${S3_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/cloudformation/${S3_KEY_PREFIX}/${MAIN_TEMPLATE_FILE}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameters file://"${REPO_DIR}/emr-on-eks/cloudformation/parameters.json" || { log "Error: Failed to create main stack."; return 1; }
        log "Creating main stack: ${MAIN_STACK_NAME}"
    fi

    aws cloudformation wait stack-create-complete --stack-name "${MAIN_STACK_NAME}" 2>/dev/null || \
    aws cloudformation wait stack-update-complete --stack-name "${MAIN_STACK_NAME}" || \
    { log "Error: Stack creation/update failed or timed out."; return 1; }

    log "Main stack deployment completed successfully"
}

# Update pre-existing IAM role trust policy with OIDC provider
update_role_trust_policy() {
    IRSA_ROLE_NAME="EmrOnEKSSparkJobExecutionRole"

    # Get OIDC
    DATASCIENCE_CLUSTER_OIDC_PROVIDER=$(get_oidc_provider "$DATA_SCIENCE_CLUSTER")
    ANALYTICS_CLUSTER_OIDC_PROVIDER=$(get_oidc_provider "$ANALYTICS_CLUSTER")
    
    log "Updating trust policy for role: $IRSA_ROLE_NAME"
    
    # Create trust policy JSON
    # Trust Policy for EMR on EKS Job Execution Role
    # This policy enables the role to be assumed by:
    # 1. EMR service principal for EMR on EKS operations
    # 2. Service accounts in EKS clusters for both:
    #    a) Spark-Operator based job submissions (using fixed service account names)
    #    b) EMR JobRun based submissions (using dynamically created service accounts)
    #
    # Note: The wildcard pattern 'emr-containers-sa-*' is used because:
    # - EMR JobRun creates dynamic service accounts with pattern: emr-containers-sa-spark-<hexadecimal_digits>
    # - This allows flexibility for both Spark-Operator and EMR JobRun execution methods
    # - All service accounts must be in the 'emr' namespace for security
    # - Actual Service Account Name is: emr-containers-sa-spark

    TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "elasticmapreduce.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    },
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${DATASCIENCE_CLUSTER_OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "${DATASCIENCE_CLUSTER_OIDC_PROVIDER}:sub": "system:serviceaccount:emr:emr-containers-sa-*",
          "${DATASCIENCE_CLUSTER_OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    },
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${ANALYTICS_CLUSTER_OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "${ANALYTICS_CLUSTER_OIDC_PROVIDER}:sub": "system:serviceaccount:emr:emr-containers-sa-*",
          "${ANALYTICS_CLUSTER_OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)
    
    # Update the role's trust policy
    aws iam update-assume-role-policy \
        --role-name "$IRSA_ROLE_NAME" \
        --policy-document "$TRUST_POLICY"
    
    log "Successfully updated trust policy for role: $IRSA_ROLE_NAME"
}


# EKS Configure script
execute_eks_configure_script() {
    local cluster_name=$1

    log "Executing $EKS_CONFIGURE_SCRIPT..."
    bash "${EKS_CONFIGURE_SCRIPT}" "$cluster_name" || { log "Error: Failed to execute $EKS_CONFIGURE_SCRIPT."; return 1; }
    log "$EKS_CONFIGURE_SCRIPT executed successfully for $cluster_name"
}

# Execute EMR EKS script for both clusters
execute_emr_eks_script() {
    local cluster_name=$1

    log "Configuring $cluster_name..."
    bash "${EMR_EKS_SCRIPT}" "$cluster_name" || \
    { log "Error: Failed to execute $EMR_EKS_SCRIPT for $cluster_name."; return 1; }
    log "$cluster_name successfully configured"
}

# Main function
main() {
    log "Setup script execution initiated..."

    # Get Account ID
    get_account_id

    # Setup and Deploy CloudFormation Stacks
    setup_s3_bucket
    upload_templates

    # Get Networking Details created in the Infra stack
    get_network_details

    # Parameters file
    create_parameter_json

    # Deploy Stack
    deploy_main_stack

    # Update IAM role with OIDC trust relationship
    update_role_trust_policy

    # Configure Data Processing EKS Clusters
    for cluster_name in "${DATA_PROCESSING_CLUSTERS[@]}"; do
        # Setup EKS Cluster
        execute_eks_configure_script "$cluster_name"
        
        # Setup EMR on EKS Cluster
        execute_emr_eks_script "$cluster_name"
    done

    log "Process completed successfully"
}

##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##
# Start the main function with all the provided arguments
##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##

# Determine the directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Set up a trap to ensure popd is called on exit
trap 'popd > /dev/null' EXIT

# Temporarily change to the script's directory
pushd "$SCRIPT_DIR" > /dev/null

# Check for help flag or any arguments
if [ $# -ne 0 ] || { [ $# -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; }; then
    usage
fi

# Check for required tools
command -v aws >/dev/null 2>&1 || { log "AWS CLI is required but it's not installed. Aborting."; exit 1; }

# No AWS CLI Output Paginated Output
export AWS_PAGER=""

# Check required environment variables
[[ -z "${AWS_REGION:-}" ]] && { log "Error: AWS_REGION is not set." >&2; exit 1; }
log "AWS Region: $AWS_REGION"

[[ -z "${REPO_DIR:-}" ]] && { log "Error: REPO_DIR is not set." >&2; exit 1; }
log "Repo Directory: $REPO_DIR"

# Call Main 
main
