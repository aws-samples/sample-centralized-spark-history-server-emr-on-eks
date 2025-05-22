#!/usr/bin/env bash

# =====================================================================================
#
# This script cleans up all resources created by the DNS deployment script.
# The cleanup is performed in the following order:
# 1. Delete DNS CloudFormation stack
#
# Note: S3 bucket is preserved intentionally
#
# =====================================================================================

set -euo pipefail

# Constants
DNS_STACK_NAME="DNS-Stack"

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "This script removes DNS entries created by the deployment script."
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

# Delete DNS CloudFormation Stack
delete_dns_stack() {
    local stack_name="${DNS_STACK_NAME}"
    
    log "Deleting DNS CloudFormation stack: ${stack_name}"
    
    if ! aws cloudformation describe-stacks --stack-name "${stack_name}" >/dev/null 2>&1; then
        log "DNS Stack ${stack_name} does not exist"
        return 0
    fi

    aws cloudformation delete-stack --stack-name "${stack_name}" || \
        { log "Error: Failed to initiate DNS stack deletion for ${stack_name}"; return 1; }

    log "Waiting for DNS stack deletion to complete..."
    aws cloudformation wait stack-delete-complete --stack-name "${stack_name}" 2>/dev/null || \
        { log "Error: DNS Stack deletion failed or timed out for ${stack_name}"; return 1; }

    log "Successfully deleted DNS stack: ${stack_name}"
}

# Show resource cleanup message
show_cleanup_message() {
    log "NOTE: The following resources have been removed:"
    log "- DNS Stack: '${DNS_STACK_NAME}'"
    log "- Route 53 DNS record"
    log ""
    log "The S3 bucket containing the CloudFormation templates is preserved."
}

# Main function
main() {
    log "DNS cleanup process execution initiated..."

    # Delete DNS CloudFormation Stack
    delete_dns_stack

    # Show cleanup message
    show_cleanup_message

    log "DNS cleanup process completed successfully"
}

##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##
# Start the main function with all the provided arguments
##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##

# Check for help flag or any arguments
if [ $# -ne 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
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