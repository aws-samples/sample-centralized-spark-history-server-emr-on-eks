#!/usr/bin/env bash

# =====================================================================================
#
# This script deploys AWS Private CA and required resources.
# The deployment is performed in the following order:
# 1. Create AWS Private CA
# 2. Issue certificate from the Private CA
# 3. Create Route 53 private hosted zone
#
# =====================================================================================

set -euo pipefail

# Constants
CFN_BUCKET_NAME_BASE="spark-history-server-cfn-templates"
S3_KEY_PREFIX="ssl"
SSL_STACK_NAME="SSL-Stack"
SSL_TEMPLATE_FILE="ssl-stack.yaml"
DOMAIN_NAME="example.internal"
RECORD_NAME="spark-history-server"

# VPC should exists already.
VPC_NAME="SHS-BaseInfraStack-VPC"

# Global Variables
AWS_ACCOUNT_ID=""
CFN_BUCKET_NAME=""
VPC_ID=""
PRIVATE_HOSTED_ZONE_ID=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "This script creates a Spark History Server Demo Private CA, certificate and Route 53"
    echo 
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region to create resources in"
    echo "  REPO_DIR      The directory containing the CloudFormation templates and scripts"
    echo 
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  export REPO_DIR=/path/to/repository"
    echo "  ./$(basename "$0")"
    exit 1
}

# Get AWS account ID
get_account_id() {
    log "Getting AWS account ID..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

    if [ -z "$AWS_ACCOUNT_ID" ]; then
        log "Error: Failed to get AWS account ID"
        return 1
    fi
    
    log "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Get VPC ID
get_vpc_id() {
    log "Getting VPC ID..."
    
    # VPC
    VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query "Vpcs[0].VpcId" \
    --output text)

    if [ -z "$VPC_ID" ]; then
        log "Error: Failed to get the VPC_ID"
        return 1
    fi
}

# Create parameters file from template
create_parameter_json() {
    log "Creating parameters file from template..."
    
    jq --arg vpc "$VPC_ID" \
       --arg domain "$DOMAIN_NAME" \
       --arg record "$RECORD_NAME" \
       '(.[] | select(.ParameterKey == "VpcId").ParameterValue) |= $vpc |
        (.[] | select(.ParameterKey == "DomainName").ParameterValue) |= $domain |
        (.[] | select(.ParameterKey == "RecordName").ParameterValue) |= $record' \
       "${REPO_DIR}/ssl/cloudformation/parameters.tpl" > "${REPO_DIR}/ssl/cloudformation/parameters.json"

    log "Created parameters file with the following values:"
    log "  VPC ID: $VPC_ID"
    log "  Domain Name: $DOMAIN_NAME"
    log "  Record Name: $RECORD_NAME"
}

# Upload AWS CloudFormation templates to S3 bucket
upload_templates() {
    log "Uploading CloudFormation templates..."
    
    # Set the CFN bucket name
    CFN_BUCKET_NAME="${CFN_BUCKET_NAME_BASE}-${AWS_ACCOUNT_ID}-${AWS_REGION}"

    # Check if bucket exists, if not create it
    if ! aws s3 ls "s3://${CFN_BUCKET_NAME}" 2>&1 > /dev/null; then
        log "Creating S3 bucket: ${CFN_BUCKET_NAME}"
        aws s3 mb "s3://${CFN_BUCKET_NAME}" --region "${AWS_REGION}" || { log "Error: Failed to create bucket."; return 1; }
    fi

    # Upload Private CA stack template
    aws s3 cp "${REPO_DIR}/ssl/cloudformation/${SSL_TEMPLATE_FILE}" "s3://${CFN_BUCKET_NAME}/cloudformation/${S3_KEY_PREFIX}/" || { log "Error: Failed to upload ${SSL_TEMPLATE_FILE}."; return 1; }
    log "Uploaded ${SSL_TEMPLATE_FILE}"
}

# Deploy CloudFormation stack
deploy_stack() {
    log "Deploying CloudFormation stack for Spark History Server Demo Private CA..."
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name "${SSL_STACK_NAME}" >/dev/null 2>&1; then
        log "Stack ${SSL_STACK_NAME} already exists, updating..."
        
        aws cloudformation update-stack \
            --stack-name "${SSL_STACK_NAME}" \
            --template-url "https://${CFN_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/cloudformation/${S3_KEY_PREFIX}/${SSL_TEMPLATE_FILE}" \
            --parameters file://"${REPO_DIR}/ssl/cloudformation/parameters.json" \
            --capabilities CAPABILITY_IAM
        
        log "Waiting for stack update to complete..."
        aws cloudformation wait stack-update-complete --stack-name "${SSL_STACK_NAME}"
    else
        log "Creating new stack: ${SSL_STACK_NAME}"
        
        aws cloudformation create-stack \
            --stack-name "${SSL_STACK_NAME}" \
            --template-url "https://${CFN_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/cloudformation/${S3_KEY_PREFIX}/${SSL_TEMPLATE_FILE}" \
            --parameters file://"${REPO_DIR}/ssl/cloudformation/parameters.json" \
            --capabilities CAPABILITY_IAM
        
        log "Waiting for stack creation to complete..."
        aws cloudformation wait stack-create-complete --stack-name "${SSL_STACK_NAME}"
    fi
    
    log "Stack deployment complete"
}


# Download private CA certificate
download_ca_certificate() {
    local output_dir="${1:-${REPO_DIR}/ssl/certificates}"
    local output_file="${output_dir}/ca-certificate.pem"
    
    log "Downloading Spark History Server Demo private CA certificate..."
    
    # Create directory if it doesn't exist
    mkdir -p "$output_dir"
    
    # Get the Spark History Server Demo Private CA ARN from CloudFormation stack outputs
    local ca_arn=$(aws cloudformation describe-stacks \
        --stack-name "${SSL_STACK_NAME}" \
        --region "${AWS_REGION}" \
        --query "Stacks[0].Outputs[?OutputKey=='PrivateCAArn'].OutputValue" \
        --output text)
    
    if [ -z "$ca_arn" ] || [ "$ca_arn" == "None" ]; then
        log "Error: Failed to get Private CA ARN from CloudFormation stack"
        return 1
    fi
    
    log "Spark History Server Demo Private CA ARN: $ca_arn"
    
    # Download the certificate
    aws acm-pca get-certificate-authority-certificate \
        --certificate-authority-arn "$ca_arn" \
        --region "${AWS_REGION}" \
        --output text > "$output_file"
    
    if [ $? -ne 0 ]; then
        log "Error: Failed to download Spark History Server Demo private CA certificate"
        return 1
    fi
    
    # Set appropriate permissions
    chmod 644 "$output_file"
    
    log "Successfully downloaded Spark History Server Demo private CA certificate to $output_file"
}

# Main function
main() {

    log "Starting Spark History Server Demo Private CA deployment process..."
    
    # Get account ID
    get_account_id
    
    # Get VPC ID
    get_vpc_id
    
    # Create parameters file
    create_parameter_json
    
    # Upload templates
    upload_templates
    
    # Deploy stack
    deploy_stack

    # Download Spark History Server Demo private CA certificate
    download_ca_certificate
    
    log "Spark History Server Demo Private CA deployment completed successfully"
}


##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##
# Start the main function with all the provided arguments
##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##

# Check for help flag or any arguments
if [ $# -ne 0 ] || { [ $# -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; }; then
    usage
fi

# Check for required tools
command -v git >/dev/null 2>&1 || { log "git is required but it's not installed. Aborting."; exit 1; }
command -v aws >/dev/null 2>&1 || { log "AWS CLI is required but it's not installed. Aborting."; exit 1; }

# No AWS CLI Output Paginated Output
export AWS_PAGER=""

# Check required environment variables
[[ -z "${AWS_REGION:-}" ]] && { log "Error: AWS_REGION is not set." >&2; exit 1; }
log "AWS Region: $AWS_REGION"

[[ -z "${REPO_DIR:-}" ]] && { log "Error: REPO_DIR is not set." >&2; exit 1; }
log "Repository Directory: $REPO_DIR"

# Call Main 
main 