#!/usr/bin/env bash

# =====================================================================================
# This script automates the deployment of EMR on EKS infrastructure by creating and 
# configuring necessary AWS resources using CloudFormation and AWS CLI commands.
#
# Key functionalities include:
# - Setting up an S3 bucket for CloudFormation templates
# - Enabling default encryption on the S3 bucket
# - Uploading required CloudFormation template files
# - Deploying/Updating the main EMR on EKS stack
# - Configuring multiple EKS clusters (datascience-cluster and analytics-cluster)
# - Setting up EMR on EKS for each cluster
# - Managing dependent stacks for ECR, EKS, and EMR roles
#
# Required environment variables:
# AWS_REGION - The AWS region where resources will be created
# REPO_DIR   - The directory containing CloudFormation templates and scripts
#
# Prerequisites:
# - AWS CLI installed and configured
# - Docker running locally
# - Appropriate AWS permissions
#
# To execute:
# export AWS_REGION=us-west-2
# export REPO_DIR=/path/to/templates
# ./deploy_emr_on_eks.sh
#
# To clean up resources:
# ./cleanup.sh
# =====================================================================================

set -euo pipefail

# Constants
BUCKET_NAME_PREFIX="spark-history-server-cfn-templates"
S3_KEY_PREFIX="infra"
MAIN_STACK_NAME="SHS-BaseInfraStack"
MAIN_TEMPLATE_FILE="main-stack.yaml"
TEMPLATE_FILES=(
    "main-stack.yaml"
    "network-stack.yaml"
    "s3-stack.yaml"
)

# Global Variables
AWS_ACCOUNT_ID=""
S3_BUCKET_NAME=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "Deploys infrastructure for Spark History Server environment using CloudFormation."
    echo "This script creates an S3 bucket for templates, uploads CloudFormation templates,"
    echo "and deploys a prerequisite stack that includes KMS, networking, and S3 resources."
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region where resources will be deployed (e.g., us-west-2)"
    echo "  REPO_DIR      The directory containing CloudFormation templates and supporting files"
    echo
    echo "Prerequisites:"
    echo "  - AWS CLI installed and configured with appropriate permissions"
    echo "  - CloudFormation templates present in REPO_DIR/infra/cloudformation/"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  export REPO_DIR=/path/to/repository"
    echo "  ./$(basename "$0")"
    exit 1
}

# Get Account Id
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    log "AWS Account ID: $AWS_ACCOUNT_ID"
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

    # Block all public access
    aws s3api put-public-access-block \
        --bucket "${S3_BUCKET_NAME}" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" || \
        { log "Error: Failed to block public access for ${S3_BUCKET_NAME}."; return 1; }
    log "Enabled block public access on S3 bucket: ${S3_BUCKET_NAME}"

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
        aws s3 cp "${REPO_DIR}/infra/cloudformation/${template}" "s3://${S3_BUCKET_NAME}/cloudformation/${S3_KEY_PREFIX}/" || { log "Error: Failed to upload ${template}."; return 1; }
        log "Uploaded ${template}"
    done
    log "All templates uploaded successfully"
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
            --parameters \
               ParameterKey=CfnTemplatesBucketName,ParameterValue="${S3_BUCKET_NAME}" \
               ParameterKey=CfnTemplateKeyPrefixName,ParameterValue="${S3_KEY_PREFIX}" || { log "Error: Failed to update main stack."; return 1; }
        log "Updating main stack: ${MAIN_STACK_NAME}"
    else
        aws cloudformation create-stack \
            --stack-name "${MAIN_STACK_NAME}" \
            --disable-rollback \
            --template-url "https://${S3_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/cloudformation/${S3_KEY_PREFIX}/${MAIN_TEMPLATE_FILE}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameters \
                ParameterKey=CfnTemplatesBucketName,ParameterValue="${S3_BUCKET_NAME}" \
                ParameterKey=CfnTemplateKeyPrefixName,ParameterValue="${S3_KEY_PREFIX}" || { log "Error: Failed to create main stack."; return 1; }
        log "Creating main stack: ${MAIN_STACK_NAME}"
    fi

    aws cloudformation wait stack-create-complete --stack-name "${MAIN_STACK_NAME}" 2>/dev/null || \
    aws cloudformation wait stack-update-complete --stack-name "${MAIN_STACK_NAME}" || \
    { log "Error: Stack creation/update failed or timed out."; return 1; }

    log "Main stack deployment completed successfully"
}

# Main function
main() {
    log "Setup script execution initiated..."

    # Get Account ID
    get_account_id

    # Setup and Deploy CloudFormation Stacks
    setup_s3_bucket
    upload_templates
    deploy_main_stack

    log "Process completed successfully"
}

##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##
# Start the main function with all the provided arguments
##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##

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
