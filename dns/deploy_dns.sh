#!/usr/bin/env bash

# =====================================================================================
#
# This script deploys Route 53 private hosted zone entry.
# The deployment is performed in the following order:
# 1. Create Route 53 private hosted zone entry
#
# =====================================================================================

set -euo pipefail

# Constants
CFN_BUCKET_NAME_BASE="spark-history-server-cfn-templates"
S3_KEY_PREFIX="dns"
DNS_STACK_NAME="DNS-Stack"
DNS_TEMPLATE_FILE="dns-stack.yaml"
DOMAIN_NAME="example.internal"
RECORD_NAME="spark-history-server"
LOAD_BALANCER_NAME="spark-history-server"

# Global Variables
AWS_ACCOUNT_ID=""
CFN_BUCKET_NAME=""
PRIVATE_HOSTED_ZONE_ID=""
LOAD_BALANCER_ARN=""
LOAD_BALANCER_DNS_NAME=""
LOAD_BALANCER_HOSTED_ZONE_ID=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "This script creates a Route 53 entry and integrates with a load balancer."
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

# Get private hosted zone ID for a domain
get_private_hosted_zone() {
    local domain=$1
    
    log "Getting private hosted zone ID for domain: $domain"
    
    # Add a dot at the end if it doesn't exist
    if [[ "$domain" != *. ]]; then
        domain="${domain}."
    fi
    
    PRIVATE_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
        --query "HostedZones[?Name=='$domain'].Id" \
        --output text | sed 's|/hostedzone/||')
    
    if [ -z "$PRIVATE_HOSTED_ZONE_ID" ] || [ "$PRIVATE_HOSTED_ZONE_ID" == "None" ]; then
        log "Error: Failed to find private hosted zone for domain $domain"
        return 1
    fi
    
    log "Found private hosted zone ID: $PRIVATE_HOSTED_ZONE_ID"
}

# Get load balancer details
get_load_balancer_details() {
    local lb_name=$1
    
    log "Getting load balancer details for: $lb_name"
    
    # Get load balancer ARN
    LOAD_BALANCER_ARN=$(aws elbv2 describe-load-balancers \
        --names "$lb_name" \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text)
    
    if [ -z "$LOAD_BALANCER_ARN" ] || [ "$LOAD_BALANCER_ARN" == "None" ]; then
        log "Error: Failed to get load balancer ARN"
        return 1
    fi
    
    # Get load balancer DNS name
    LOAD_BALANCER_DNS_NAME=$(aws elbv2 describe-load-balancers \
        --names "$lb_name" \
        --query 'LoadBalancers[0].DNSName' \
        --output text)
    
    # Get load balancer hosted zone ID
    LOAD_BALANCER_HOSTED_ZONE_ID=$(aws elbv2 describe-load-balancers \
        --names "$lb_name" \
        --query 'LoadBalancers[0].CanonicalHostedZoneId' \
        --output text)
    
    log "Load balancer ARN: $LOAD_BALANCER_ARN"
    log "Load balancer DNS name: $LOAD_BALANCER_DNS_NAME"
    log "Load balancer hosted zone ID: $LOAD_BALANCER_HOSTED_ZONE_ID"
}

# Create parameters file from template
create_parameter_json() {
    log "Creating parameters file from template..."
    
    jq --arg lb_arn "$LOAD_BALANCER_ARN" \
       --arg lb_dns "$LOAD_BALANCER_DNS_NAME" \
       --arg lb_zone "$LOAD_BALANCER_HOSTED_ZONE_ID" \
       --arg domain "$DOMAIN_NAME" \
       --arg record "$RECORD_NAME" \
       --arg hosted_zone "$PRIVATE_HOSTED_ZONE_ID" \
       '(.[] | select(.ParameterKey == "LoadBalancerArn").ParameterValue) |= $lb_arn |
        (.[] | select(.ParameterKey == "LoadBalancerDnsName").ParameterValue) |= $lb_dns |
        (.[] | select(.ParameterKey == "LoadBalancerHostedZoneId").ParameterValue) |= $lb_zone |
        (.[] | select(.ParameterKey == "DomainName").ParameterValue) |= $domain |
        (.[] | select(.ParameterKey == "RecordName").ParameterValue) |= $record |
        (.[] | select(.ParameterKey == "HostedZoneId").ParameterValue) |= $hosted_zone' \
       "${REPO_DIR}/dns/cloudformation/parameters.tpl" > "${REPO_DIR}/dns/cloudformation/parameters.json"

    log "Created parameters file with the following values:"
    log "  Load Balancer ARN: $LOAD_BALANCER_ARN"
    log "  Load Balancer ARN: $LOAD_BALANCER_DNS_NAME"
    log "  Load Balancer ARN: $LOAD_BALANCER_HOSTED_ZONE_ID"
    log "  Domain Name: $DOMAIN_NAME"
    log "  Record Name: $RECORD_NAME"
    log "  Hosted Zone ID: $PRIVATE_HOSTED_ZONE_ID"
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

    # Upload
    aws s3 cp "${REPO_DIR}/dns/cloudformation/${DNS_TEMPLATE_FILE}" "s3://${CFN_BUCKET_NAME}/cloudformation/${S3_KEY_PREFIX}/" || { log "Error: Failed to upload ${DNS_TEMPLATE_FILE}."; return 1; }
    log "Uploaded ${DNS_TEMPLATE_FILE}"
}

# Deploy CloudFormation stack
deploy_stack() {
    log "Deploying CloudFormation stack for Private CA..."
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name "${DNS_STACK_NAME}" >/dev/null 2>&1; then
        log "Stack ${DNS_STACK_NAME} already exists, updating..."
        
        aws cloudformation update-stack \
            --stack-name "${DNS_STACK_NAME}" \
            --template-url "https://${CFN_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/cloudformation/${S3_KEY_PREFIX}/${DNS_TEMPLATE_FILE}" \
            --parameters file://"${REPO_DIR}/dns/cloudformation/parameters.json" \
            --capabilities CAPABILITY_IAM
        
        log "Waiting for stack update to complete..."
        aws cloudformation wait stack-update-complete --stack-name "${DNS_STACK_NAME}"
    else
        log "Creating new stack: ${DNS_STACK_NAME}"
        
        aws cloudformation create-stack \
            --stack-name "${DNS_STACK_NAME}" \
            --template-url "https://${CFN_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/cloudformation/${S3_KEY_PREFIX}/${DNS_TEMPLATE_FILE}" \
            --parameters file://"${REPO_DIR}/dns/cloudformation/parameters.json" \
            --capabilities CAPABILITY_IAM
        
        log "Waiting for stack creation to complete..."
        aws cloudformation wait stack-create-complete --stack-name "${DNS_STACK_NAME}"
    fi
    
    log "Stack deployment complete"
}

# Main function
main() {

    log "Starting Route53 Entry deployment process..."
    
    # Get account ID
    get_account_id

    # Get private hosted zone ID
    get_private_hosted_zone "$DOMAIN_NAME"
    
    # Get load balancer details
    get_load_balancer_details "$LOAD_BALANCER_NAME"
    
    # Create parameters file
    create_parameter_json
    
    # Upload templates
    upload_templates
    
    # Deploy stack
    deploy_stack
    
    log "DNS Stack deployment completed successfully"
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