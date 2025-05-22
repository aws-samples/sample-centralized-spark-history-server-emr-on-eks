#!/usr/bin/env bash

# =====================================================================================
# This script handles the cleanup of AWS resources created by the deploy_infra.sh script.
# It removes CloudFormation stacks and provides information about preserved S3 buckets.
#
# Key functionalities include:
# - Deleting the main CloudFormation stack and its nested stacks
# - Preserving S3 buckets for manual cleanup
# - Providing cleanup verification and status messages
# - Handling error scenarios and stack deletion failures
#
# Required environment variables:
# AWS_REGION - The AWS region where resources will be cleaned up
#
# Prerequisites:
# - AWS CLI installed and configured
# - Appropriate AWS permissions to delete resources
#
# To execute:
# export AWS_REGION=us-west-2
# ./cleanup.sh
#
# Note: S3 buckets are preserved and must be cleaned up manually
# =====================================================================================

set -euo pipefail

# Constants
BUCKET_NAME_PREFIX="spark-history-server-cfn-templates"
MAIN_STACK_NAME="SHS-BaseInfraStack"

# Global Variables
AWS_ACCOUNT_ID=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "Cleans up AWS resources created by the deploy_infra.sh script."
    echo "This script deletes CloudFormation stacks but preserves S3 buckets for manual cleanup."
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region where resources will be cleaned up (e.g., us-west-2)"
    echo
    echo "Prerequisites:"
    echo "  - AWS CLI installed and configured with appropriate permissions"
    echo "  - Resources deployed using deploy_infra.sh script"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  ./$(basename "$0")"
    exit 1
}

# Get Account Id
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    log "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Show S3 bucket retention message
show_s3_bucket_message() {
    # Set the CFN bucket name
    CFN_BUCKET_NAME="${BUCKET_NAME_PREFIX}-${AWS_ACCOUNT_ID}-${AWS_REGION}"
    
    log "NOTE: The following S3 bucket is intentionally preserved:"
    log "- CFN bucket: '$CFN_BUCKET_NAME'"
    log ""
    log "If you want to delete it manually, use:"
    log "aws s3 rb s3://$CFN_BUCKET_NAME --force"
}

# Delete Extraneous Security Groups created outside of the CFN. 
delete_security_groups() {
    # List of patterns to match
    patterns=(
        "k8s-sparkhis-sparkhis-*"
        "k8s-traffic-sparkhistoryserver-*"
    )

    for pattern in "${patterns[@]}"; do
        echo "Looking for Security Groups matching pattern: $pattern"
        
        # Get list of security group IDs matching the pattern
        sg_ids=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=$pattern" \
            --query 'SecurityGroups[*].GroupId' \
            --output text 2>/dev/null)

        if [ -z "$sg_ids" ]; then
            echo "No security groups found matching pattern: $pattern"
            continue
        fi

        for sg_id in $sg_ids; do
            echo "Deleting Security Group: $sg_id"
            aws ec2 delete-security-group --group-id "$sg_id" 2>/dev/null || true
        done
    done
}


# Delete CloudFormation stack
delete_cloudformation_stack() {
    local stack_name=$1
    
    if aws cloudformation describe-stacks --stack-name "${stack_name}" >/dev/null 2>&1; then
        log "Deleting stack: ${stack_name}"
        aws cloudformation delete-stack --stack-name "${stack_name}" || { log "Error: Failed to initiate deletion of stack ${stack_name}"; return 1; }
        
        log "Waiting for stack deletion to complete..."
        aws cloudformation wait stack-delete-complete --stack-name "${stack_name}" || { log "Error: Stack deletion failed or timed out for ${stack_name}"; return 1; }
        log "Stack ${stack_name} deleted successfully"
    else
        log "Stack ${stack_name} does not exist"
    fi
}

# Cleanup resources
cleanup_resources() {
    log "Starting cleanup process..."

    # Delete main stack (this will also delete nested stacks)
    delete_cloudformation_stack "${MAIN_STACK_NAME}"

    # Show S3 bucket retention message
    show_s3_bucket_message

    log "Cleanup completed successfully"
}

# Main function
main() {
    log "Cleanup script execution initiated..."

    # Get Account ID
    get_account_id

    # Delete Security Groups
    delete_security_groups

    # Perform cleanup
    cleanup_resources

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

# Call Main
main