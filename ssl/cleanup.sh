#!/usr/bin/env bash

# =====================================================================================
#
# This script cleans up all resources created by the ssl.sh script.
# The cleanup is performed in the following order:
# 1. Delete SSL CloudFormation stack (including Private CA, certificates, and Route 53 resources)
#
# Note: S3 bucket is preserved intentionally
#
# =====================================================================================

set -euo pipefail

# Constants
CFN_BUCKET_NAME_BASE="spark-history-server-cfn-templates"
SSL_STACK_NAME="SSL-Stack"

# Global Variables
AWS_ACCOUNT_ID=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "This script removes the Private CA, certificate, and Route 53 resources created by ssl.sh."
    echo 
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region where resources exist"
    echo "  REPO_DIR      The directory containing the scripts and templates"
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

# Delete SSL CloudFormation Stack
delete_ssl_stack() {
    local stack_name="${SSL_STACK_NAME}"
    
    log "Deleting SSL CloudFormation stack: ${stack_name}"
    
    if ! aws cloudformation describe-stacks --stack-name "${stack_name}" >/dev/null 2>&1; then
        log "SSL Stack ${stack_name} does not exist"
        return 0
    fi

    # Check if we need to delete certificates first
    local ca_arn=$(aws cloudformation describe-stacks \
        --stack-name "${stack_name}" \
        --query "Stacks[0].Outputs[?OutputKey=='PrivateCAArn'].OutputValue" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$ca_arn" ] && [ "$ca_arn" != "None" ]; then
        log "Found Private CA: $ca_arn - preparing for deletion"
        
        # Check if the CA is enabled and needs to be disabled before deletion
        local ca_status=$(aws acm-pca describe-certificate-authority \
            --certificate-authority-arn "$ca_arn" \
            --query 'CertificateAuthority.Status' \
            --output text 2>/dev/null || echo "NOT_FOUND")
        
        if [ "$ca_status" == "ACTIVE" ]; then
            log "Disabling Private CA before stack deletion"
            aws acm-pca update-certificate-authority \
                --certificate-authority-arn "$ca_arn" \
                --status DISABLED || log "Warning: Could not disable CA, proceeding with stack deletion"
        fi
    fi

    aws cloudformation delete-stack --stack-name "${stack_name}" || \
        { log "Error: Failed to initiate SSL stack deletion for ${stack_name}"; return 1; }

    log "Waiting for SSL stack deletion to complete..."
    aws cloudformation wait stack-delete-complete --stack-name "${stack_name}" 2>/dev/null || \
        { log "Error: SSL Stack deletion failed or timed out for ${stack_name}"; return 1; }

    log "Successfully deleted SSL stack: ${stack_name}"
}

# Show S3 bucket retention message
show_s3_bucket_message() {
    # Set the CFN bucket name
    CFN_BUCKET_NAME="${CFN_BUCKET_NAME_BASE}-${AWS_ACCOUNT_ID}-${AWS_REGION}"
    
    log "NOTE: The following S3 bucket is intentionally preserved:"
    log "- CFN bucket: '$CFN_BUCKET_NAME'"
    log ""
    log "If you want to delete it manually, use:"
    log "aws s3 rb s3://$CFN_BUCKET_NAME --force"
}

# Main function
main() {
    log "SSL cleanup process execution initiated..."

    # Get account ID
    get_account_id

    # Delete SSL CloudFormation Stack
    delete_ssl_stack

    # Show S3 bucket retention message
    show_s3_bucket_message

    log "SSL cleanup process completed successfully"
}

##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##
# Start the main function with all the provided arguments
##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##

# Check for help flag or any arguments
if [ $# -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
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
log "Repository Directory: $REPO_DIR"

# Call Main 
main