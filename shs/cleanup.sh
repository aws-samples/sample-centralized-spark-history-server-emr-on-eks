#!/usr/bin/env bash

# ~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~ #
#
# Script: cleanup.sh
# Description: This script cleans up resources deployed by deploy_shs.sh for Spark History Server on Amazon EKS.
#
# ~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~ #

set -euo pipefail

# Constants

CFN_BUCKET_NAME_BASE="spark-history-server-cfn-templates"
SHS_STACK_NAME="SHS-SparkHistoryServerStack"
SHS_CLUSTER_NAME="spark-history-server"
SHS_ECR_REPO_NAME="spark-history-server"
SPARK_LOGS_BUCKET_NAME_BASE="emr-spark-logs"

NAMESPACE="spark-history"
SERVICE_ACCOUNT_NAME="spark-history-server-sa"
IAM_ROLE_NAME="spark-history-server-irsa-role"

# Global Variables
AWS_ACCOUNT_ID=""
CFN_BUCKET_NAME=""
SPARK_LOGS_BUCKET_NAME=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "This script cleans up resources deployed by deploy_shs.sh"
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION                The AWS region where resources were deployed"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  ./$(basename "$0")"
    exit 1
}

# Get Account ID
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        log "Error: Failed to get the AWS_ACCOUNT_ID"
        return 1
    fi
}

# Show S3 bucket retention message
show_s3_bucket_message() {
    log "NOTE: The following S3 buckets are intentionally preserved:"
    log "- CFN bucket: '$CFN_BUCKET_NAME'"
    log "- Spark logs bucket: '$SPARK_LOGS_BUCKET_NAME'"
    log ""
    log "If you want to delete them manually, use:"
    log "aws s3 rb s3://$CFN_BUCKET_NAME --force"
    log "aws s3 rb s3://$SPARK_LOGS_BUCKET_NAME --force"
}

# Delete ECR repository
delete_ecr_repository() {
    log "Deleting ECR repository: $SHS_ECR_REPO_NAME"
    if aws ecr describe-repositories --repository-names "$SHS_ECR_REPO_NAME" >/dev/null 2>&1; then
        aws ecr delete-repository \
            --repository-name "$SHS_ECR_REPO_NAME" \
            --force || log "Warning: Failed to delete ECR repository"
    else
        log "ECR repository $SHS_ECR_REPO_NAME does not exist"
    fi
}

# Update kubeconfig
update_kubeconfig() {
    log "Updating kubeconfig for cluster: $SHS_CLUSTER_NAME"
    if aws eks describe-cluster --name "$SHS_CLUSTER_NAME" >/dev/null 2>&1; then
        aws eks update-kubeconfig --name "$SHS_CLUSTER_NAME" --region "$AWS_REGION"
    else
        log "Cluster $SHS_CLUSTER_NAME does not exist"
        return 0
    fi
}

# Uninstall AWS Load Balancer Controller
uninstall_aws_lb_controller() {
    local namespace="kube-system"
    local release_name="aws-load-balancer-controller"

    echo "Checking for AWS Load Balancer Controller in namespace: ${namespace}"

    # Check if the release exists
    if helm list -n "${namespace}" | grep -q "${release_name}"; then
        echo "Uninstalling AWS Load Balancer Controller..."
        helm uninstall "${release_name}" -n "${namespace}"
        
        if [ $? -eq 0 ]; then
            echo "Successfully uninstalled AWS Load Balancer Controller"
        else
            echo "Failed to uninstall AWS Load Balancer Controller"
            return 1
        fi
    else
        echo "AWS Load Balancer Controller release not found in namespace: ${namespace}"
        return 0
    fi
}

# Delete AWS Load Balancer Conteoller Add-Ons.
delete_aws_lb_controller_sa_stack() {
    local cluster_name="${SHS_CLUSTER_NAME}"
    local stack_name="eksctl-${cluster_name}-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"

    # Check if stack exists
    if ! aws cloudformation describe-stacks --stack-name "${stack_name}" >/dev/null 2>&1; then
        echo "Stack ${stack_name} does not exist"
        return 0
    fi

    echo "Deleting IAM service account stack: ${stack_name}"
    aws cloudformation delete-stack --stack-name "${stack_name}" || \
        { echo "Error: Failed to initiate stack deletion for ${stack_name}"; return 1; }

    echo "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete --stack-name "${stack_name}" 2>/dev/null || \
        { echo "Error: Stack deletion failed or timed out for ${stack_name}"; return 1; }

    echo "Successfully deleted IAM service account stack: ${stack_name}"
    return 0
}

# Delete Internal Application Load Balancer
delete_load_balancer() {
    local lb_name="spark-history-server"
    log "Checking for internal Application Load Balancer: ${lb_name}"

    # Get the ALB ARN
    local alb_arn=$(aws elbv2 describe-load-balancers \
        --names "${lb_name}" \
        --query 'LoadBalancers[?Scheme==`internal`].LoadBalancerArn' \
        --output text 2>/dev/null)

    if [[ -z "${alb_arn}" || "${alb_arn}" == "None" ]]; then
        log "No internal Application Load Balancer found with name: ${lb_name}"
        return 0
    fi

    log "Found internal Application Load Balancer: ${lb_name}"
    
    # Delete listeners first
    local listeners=$(aws elbv2 describe-listeners \
        --load-balancer-arn "${alb_arn}" \
        --query 'Listeners[*].ListenerArn' \
        --output text)
    
    if [[ -n "${listeners}" ]]; then
        for listener in ${listeners}; do
            log "Deleting listener: ${listener}"
            aws elbv2 delete-listener --listener-arn "${listener}" || \
                { log "Error: Failed to delete listener ${listener}"; return 1; }
        done
    fi

    # Delete the ALB
    log "Deleting Application Load Balancer: ${lb_name}"
    aws elbv2 delete-load-balancer --load-balancer-arn "${alb_arn}" || \
        { log "Error: Failed to delete Application Load Balancer ${lb_name}"; return 1; }
    
    # Wait for deletion to complete
    log "Waiting for Load Balancer deletion to complete..."
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "${alb_arn}" || \
        { log "Error: Timeout waiting for Load Balancer deletion"; return 1; }
    
    log "Application Load Balancer deleted successfully"
    return 0
}

# Clean up Kubernetes resources
cleanup_kubernetes_resources() {
    log "Cleaning up Kubernetes resources..."

    # Check if cluster exists before attempting to delete resources
    if ! aws eks describe-cluster --name "$SHS_CLUSTER_NAME" >/dev/null 2>&1; then
        log "Cluster $SHS_CLUSTER_NAME does not exist, skipping Kubernetes cleanup"
        return 0
    fi

    # Delete AWS Load Balancer Controller
    log "Removing AWS Load Balancer Controller..."
    uninstall_aws_lb_controller

    log "Removing AWS Load Balancer Controller  Add-Ons..."
    delete_aws_lb_controller_sa_stack

    # Delete Spark History Server deployment
    log "Removing Spark History Server..."
    helm uninstall spark-history-server -n "$NAMESPACE" || true
}

# Delete IAM resources
delete_iam_resources() {
    log "Deleting IAM resources..."

    # Delete Load Balancer Controller IAM role
    aws iam delete-role-policy --role-name AmazonEKSLoadBalancerControllerRole --policy-name AWSLoadBalancerControllerIAMPolicy-part1 2>/dev/null || true
    aws iam delete-role-policy --role-name AmazonEKSLoadBalancerControllerRole --policy-name AWSLoadBalancerControllerIAMPolicy-part2 2>/dev/null || true
    aws iam delete-role --role-name AmazonEKSLoadBalancerControllerRole 2>/dev/null || true

    log "Deleted IAM role and its policies"

    # Attempt to delete standalone policies
    for policy in "AWSLoadBalancerControllerIAMPolicy-part1" "AWSLoadBalancerControllerIAMPolicy-part2"; do
        local policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='$policy'].Arn" --output text)
        if [ ! -z "$policy_arn" ]; then
            aws iam delete-policy --policy-arn "$policy_arn" 2>/dev/null || true
        fi
    done

    log "Deleted standalone policies if any"

}

# Delete CloudFormation stack
delete_cloudformation_stack() {
    log "Deleting CloudFormation stack: $SHS_STACK_NAME"
    if aws cloudformation describe-stacks --stack-name "$SHS_STACK_NAME" >/dev/null 2>&1; then
        aws cloudformation delete-stack --stack-name "$SHS_STACK_NAME"
        log "Waiting for stack deletion to complete..."
        aws cloudformation wait stack-delete-complete --stack-name "$SHS_STACK_NAME"
    else
        log "Stack $SHS_STACK_NAME does not exist"
    fi
}

# Main function
main() {
    log "Starting cleanup process..."

    # Get Account ID
    get_account_id

    CFN_BUCKET_NAME="${CFN_BUCKET_NAME_BASE}-${AWS_ACCOUNT_ID}-${AWS_REGION}"
    SPARK_LOGS_BUCKET_NAME="${SPARK_LOGS_BUCKET_NAME_BASE}-${AWS_ACCOUNT_ID}-${AWS_REGION}"

    # Update kubeconfig
    update_kubeconfig

    # Clean up Kubernetes resources
    cleanup_kubernetes_resources

    # Delete CRDs and other resources
    delete_load_balancer

    # Delete ECR repository
    delete_ecr_repository

    # Delete IAM resources
    delete_iam_resources

    # Delete CloudFormation stack
    delete_cloudformation_stack

    # Show S3 bucket retention message
    show_s3_bucket_message

    log "Cleanup process completed"
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
command -v kubectl >/dev/null 2>&1 || { log "kubectl is required but it's not installed. Aborting."; exit 1; }
command -v helm >/dev/null 2>&1 || { log "Helm is required but it's not installed. Aborting."; exit 1; }

# No AWS CLI Output Paginated Output
export AWS_PAGER=""

# Check required environment variables
[[ -z "${AWS_REGION:-}" ]] && { log "Error: AWS_REGION is not set." >&2; exit 1; }
log "AWS Region: $AWS_REGION"

# Call Main
main