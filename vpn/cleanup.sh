#!/usr/bin/env bash

# =====================================================================================
#
# This script cleans up all resources created by the deploy_vpn.sh script.
# The cleanup is performed in the following order:
# 1. Delete VPN CloudFormation stack
# 2. Delete ACM certificates
# 3. Remove local certificate files
#
# Note: S3 bucket is preserved intentionally
#
# =====================================================================================


set -euo pipefail

# Constants

CFN_BUCKET_NAME_BASE="spark-history-server-cfn-templates"
VPN_STACK_NAME="SHS-VPNStack"   

SHS_CLUSTER_NAME="spark-history-server"
NAMESPACE="spark-history"
SHS_ECR_REPOSITORY_NAME="spark-history-server"
SERVER_NAME="shs-vpn-server"

IAM_ROLE_NAME="spark-history-server-irsa-role"
IAM_POLICY_NAME="spark-history-server-s3-policy"

CERT_DIR="client_vpn_certs"

# Global Variables
AWS_ACCOUNT_ID=""
SHS_CONTEXT_NAME=""


# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Account Id
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

    if [ -z "$AWS_ACCOUNT_ID" ]; then
        log "Error: Failed to get the AWS_ACCOUNT_ID"
        return 1
    fi
}

# Delete VPN CloudFormation Stack
delete_vpn_stack() {
    local stack_name="${VPN_STACK_NAME}"
    
    log "Deleting VPN CloudFormation stack: ${stack_name}"
    
    if ! aws cloudformation describe-stacks --stack-name "${stack_name}" >/dev/null 2>&1; then
        log "VPN Stack ${stack_name} does not exist"
        return 0
    fi

    aws cloudformation delete-stack --stack-name "${stack_name}" || \
        { log "Error: Failed to initiate VPN stack deletion for ${stack_name}"; return 1; }

    log "Waiting for VPN stack deletion to complete..."
    aws cloudformation wait stack-delete-complete --stack-name "${stack_name}" 2>/dev/null || \
        { log "Error: VPN Stack deletion failed or timed out for ${stack_name}"; return 1; }

    log "Successfully deleted VPN stack: ${stack_name}"
}

# Check for existing certificates in ACM
check_existing_certificates() {
    log "Checking for existing server certificate in ACM..."

    # Check for server certificate
    SERVER_CERT_ARN=$(aws acm list-certificates --query "CertificateSummaryList[?contains(DomainName, '${SERVER_NAME}')].CertificateArn" --output text)

    if [ -n "$SERVER_CERT_ARN" ]; then
        log "Found existing certificate:"
        log "Certificate ARN: $SERVER_CERT_ARN"
        return 0
    fi

    log "Certificate not found. Need to generate new certificate."
    return 1
}

# Delete Certificate from ACM
delete_certificate() {
    
    local cert_arn="${SERVER_CERT_ARN}"
    
    if [ -z "${cert_arn}" ]; then
        log "No certificate ARN found. Skipping certificate deletion."
        return 0
    fi

    log "Deleting certificate from ACM: ${cert_arn}"
    
    aws acm delete-certificate --certificate-arn "${cert_arn}" || \
        { log "Error: Failed to delete certificate ${cert_arn}"; return 1; }

    log "Successfully deleted certificate: ${cert_arn}"
}

# Cleanup local certificate files
cleanup_local_certs() {
    local cert_dir="${REPO_DIR}/vpn/${CERT_DIR}"
    
    log "Cleaning up local certificate files in ${cert_dir}"
    
    if [ -d "${cert_dir}" ]; then
        rm -rf "${cert_dir}"
        log "Successfully removed local certificate directory"
    else
        log "Certificate directory does not exist"
    fi
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
  log "Cleanup process execution initiated..."

  # Get AWS_ACCOUNT_ID
  get_account_id

  # Delete VPN CloudFormation Stack
  delete_vpn_stack

  # Check if certificates exist in ACM
  if check_existing_certificates; then
     # Delete Certificate from ACM
     delete_certificate
  fi

  # Clean up local certificate files
  cleanup_local_certs

  # Show S3 bucket retention message
  show_s3_bucket_message

  log "Cleanup process completed successfully"
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
command -v docker >/dev/null 2>&1 || { log "Docker is required but it's not installed. Aborting."; exit 1; }
command -v helm >/dev/null 2>&1 || { log "Helm is required but it's not installed. Aborting."; exit 1; }

# No AWS CLI Output Paginated Output
export AWS_PAGER=""

# Check required environment variables
[[ -z "${AWS_REGION:-}" ]] && { log "Error: AWS_REGION is not set." >&2; exit 1; }
log "AWS Region: $AWS_REGION"

[[ -z "${REPO_DIR:-}" ]] && { log "Error: REPO_DIR is not set." >&2; exit 1; }
log "Repository Directory: $REPO_DIR"

# Call Main 
main