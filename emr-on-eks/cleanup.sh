#!/bin/bash
set -euo pipefail

# =====================================================================================
# This script cleans up all resources created by the deploy_emr_on_eks.sh script.
# The cleanup is performed in the following order:
# 1. Delete EMR virtual clusters
# 2. Delete EKS clusters
# 3. Delete CloudFormation stack
# Note: S3 bucket is preserved intentionally
# =====================================================================================

# Constants
BUCKET_NAME_PREFIX="spark-history-server-cfn-templates"
MAIN_STACK_NAME="SHS-EMROnEKSStack"

# ECR Repo Name
EMR_ECR_REPO_NAME="emr-7.2.0_custom"

# EKS Clusters
DATA_SCIENCE_CLUSTER="datascience-cluster"
ANALYTICS_CLUSTER="analytics-cluster"

# List of EKS Clusters
DATA_PROCESSING_CLUSTERS=(
    $DATA_SCIENCE_CLUSTER
    $ANALYTICS_CLUSTER
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
    echo "This script cleans up all resources created by the deploy_emr_on_eks.sh script."
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region where resources were created"
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

# Delete ECR repository
delete_ecr_repository() {
    log "Deleting ECR repository: $EMR_ECR_REPO_NAME"
    if aws ecr describe-repositories --repository-names "$EMR_ECR_REPO_NAME" >/dev/null 2>&1; then
        aws ecr delete-repository \
            --repository-name "$EMR_ECR_REPO_NAME" \
            --force || log "Warning: Failed to delete ECR repository"
    else
        log "ECR repository $EMR_ECR_REPO_NAME does not exist"
    fi
}

# Delete EMR virtual clusters
delete_emr_virtual_clusters() {
    local cluster_name=$1
    log "Deleting EMR virtual clusters for EKS cluster: $cluster_name"
    
    # List and delete all virtual clusters associated with the EKS cluster
    virtual_clusters=$(aws emr-containers list-virtual-clusters \
        --query "virtualClusters[?state!='TERMINATED' && containerProvider.id=='${cluster_name}'].id" \
        --output text)
    
    if [ -n "$virtual_clusters" ]; then
        for vc_id in $virtual_clusters; do
            log "Deleting virtual cluster: $vc_id"
            aws emr-containers delete-virtual-cluster --id "$vc_id"
            
            # Wait for virtual cluster deletion
            while true; do
                status=$(aws emr-containers list-virtual-clusters \
                    --query "virtualClusters[?id=='${vc_id}'].state" \
                    --output text)
                if [ "$status" == "TERMINATED" ]; then
                    break
                fi
                log "Waiting for virtual cluster $vc_id to be deleted..."
                sleep 10
            done
        done
    else
        log "No active virtual clusters found for EKS cluster: $cluster_name"
    fi
}

# Delete EKS cluster
delete_eks_cluster() {
    local cluster_name=$1
    log "Deleting EKS cluster: $cluster_name"
    
    # Check if cluster exists
    if aws eks describe-cluster --name "$cluster_name" >/dev/null 2>&1; then
        # Delete any node groups
        nodegroups=$(aws eks list-nodegroups --cluster-name "$cluster_name" --query 'nodegroups[*]' --output text)
        if [ -n "$nodegroups" ]; then
            for ng in $nodegroups; do
                log "Deleting node group: $ng"
                aws eks delete-nodegroup --cluster-name "$cluster_name" --nodegroup-name "$ng"
                aws eks wait nodegroup-deleted --cluster-name "$cluster_name" --nodegroup-name "$ng"
            done
        fi
        
        # Delete the cluster
        aws eks delete-cluster --name "$cluster_name"
        aws eks wait cluster-deleted --name "$cluster_name"
        log "EKS cluster $cluster_name deleted successfully"
    else
        log "EKS cluster $cluster_name does not exist"
    fi
}

# Delete CloudFormation stack
delete_cloudformation_stack() {
    log "Deleting CloudFormation stack: $MAIN_STACK_NAME"
    
    if aws cloudformation describe-stacks --stack-name "$MAIN_STACK_NAME" >/dev/null 2>&1; then
        aws cloudformation delete-stack --stack-name "$MAIN_STACK_NAME"
        aws cloudformation wait stack-delete-complete --stack-name "$MAIN_STACK_NAME"
        log "CloudFormation stack deleted successfully"
    else
        log "CloudFormation stack $MAIN_STACK_NAME does not exist"
    fi
}

# Show S3 bucket retention message
show_s3_bucket_message() {
    S3_BUCKET_NAME="${BUCKET_NAME_PREFIX}-${AWS_ACCOUNT_ID}-${AWS_REGION}"
    log "NOTE: S3 bucket '$S3_BUCKET_NAME' is intentionally preserved"
    log "If you want to delete it manually, use: aws s3 rb s3://$S3_BUCKET_NAME --force"
}

# Main function
main() {
    log "Cleanup script execution initiated..."

    # Get Account ID
    get_account_id

    # Delete ECR repository
    delete_ecr_repository
    
    # Delete resources for each cluster
    for cluster_name in "${DATA_PROCESSING_CLUSTERS[@]}"; do
        # Delete EMR virtual clusters first
        delete_emr_virtual_clusters "$cluster_name"
        
        # Delete EKS cluster
        delete_eks_cluster "$cluster_name"
    done
    
    # Delete CloudFormation stack
    delete_cloudformation_stack
    
    # Show S3 bucket retention message
    show_s3_bucket_message
    
    log "Cleanup process completed successfully"
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

# Call Main
main