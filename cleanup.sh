#!/usr/bin/env bash

# =====================================================================================
#
# This script executes all cleanup scripts in a specific order to remove all resources.
# The cleanup is performed in the following order:
# 1. VPN resources cleanup
# 2. Spark History Server (SHS) cleanup
# 3. EMR on EKS cleanup
# 4. Infrastructure cleanup
#
# Note: Each cleanup script is self-contained and handles its own resource cleanup
#
# =====================================================================================

set -euo pipefail

# Constants
CLEANUP_SCRIPTS=(
    "vpn/cleanup.sh"
    "dns/cleanup.sh"
    "shs/cleanup.sh"
    "ssl/cleanup.sh"
    "emr-on-eks/cleanup.sh"
    "infra/cleanup.sh"
)

# Globals
AWS_ACCOUNT_ID=""

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

# Empty S3 bucket and delete
delete_s3_bucket() {
    local versions
    local delete_markers
    local s3_bucket_name="$1"

    if aws s3api head-bucket --bucket "$s3_bucket_name" 2>/dev/null; then
        echo "Bucket $s3_bucket_name exists"

        log "Preparing to empty S3 bucket: $s3_bucket_name"

        # List and delete all versions of objects in the bucket
        versions=$(aws s3api list-object-versions --bucket "$s3_bucket_name" --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json)
        if [[ -z "$versions" || "$versions" == "null" || "$versions" == "[]" ]]; then
        log "No object versions found in the bucket."
        else
            # Delete all object versions
            if aws s3api delete-objects --bucket "$s3_bucket_name" --delete "{\"Objects\": $versions}" --output text; then
                log "All object versions deleted successfully."
            else
                log "Error occurred while deleting object versions."
                return 1
            fi
        fi

        # List and delete all delete markers in the bucket
        delete_markers=$(aws s3api list-object-versions --bucket "$s3_bucket_name" --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json)

        if [[ -z "$delete_markers" || "$delete_markers" == "null" || "$delete_markers" == "[]"  ]]; then
            log "No delete markers found in the bucket."
        else
            # Delete all delete markers
            if aws s3api delete-objects --bucket "$s3_bucket_name" --delete "{\"Objects\": $delete_markers}" --output text; then
                log "All delete markers deleted successfully."
            else
                log "Error occurred while deleting delete markers."
                return 1
            fi
        fi

        log "S3 bucket: $s3_bucket_name emptied"

      
        # Delete the bucket
        log "Deleting S3 bucket: $s3_bucket_name"

        aws s3api delete-bucket --bucket "${s3_bucket_name}" 2>/dev/null || {
            echo "Failed to delete bucket ${s3_bucket_name}"
            return 1
        }
    else
        echo "Bucket $s3_bucket_name does not exist"
    fi

    echo "Bucket ${s3_bucket_name} deleted"
    return 0
}

# Execute cleanup script
execute_cleanup() {
    local script_path="$1"
    
    log "Executing cleanup script: ${script_path}"
    "${REPO_DIR}/${script_path}" || { log "Error: Failed to execute ${script_path}"; return 1; }
    log "Successfully completed cleanup: ${script_path}"
}

# Main function
main() {
    log "Starting cleanup process..."

    # Get Account ID
    get_account_id

    # Delete S3 buckets
    log "Cleaning up emr-spark-logs S3 buckets"
    delete_s3_bucket "emr-spark-logs-${AWS_ACCOUNT_ID}-${AWS_REGION}"


    # Execute each cleanup script in order
    for script in "${CLEANUP_SCRIPTS[@]}"; do
        execute_cleanup "$script"
    done

    # Delete S3 buckets
    log "Cleaning up spark-history-server-cfn-templates S3 buckets"
    delete_s3_bucket "spark-history-server-cfn-templates-${AWS_ACCOUNT_ID}-${AWS_REGION}"

    log "All cleanup processes completed successfully"
}

##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##
# Start the main function with all the provided arguments
##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##

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