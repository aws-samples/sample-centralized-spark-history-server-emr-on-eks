#!/bin/bash

set -euo pipefail

# =====================================================================================
# This script configures the EKS Cluster with Metrics Server and OIDC Provider.
# 
# Key functionalities include:
# - Setting up kubectl context for the specified EKS cluster
# - Associate OIDC Provider
# - Deploy Metrics Server
#
# Usage: ./script_name.sh CLUSTER_NAME
#
# Required environment variables:
# - AWS_REGION: The AWS region to deploy resources
# =====================================================================================

# Script variables

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Check Dependencies
check_dependencies() {
    command -v aws >/dev/null 2>&1 || { log "AWS CLI is required but it's not installed. Aborting."; exit 1; }
    command -v eksctl >/dev/null 2>&1 || { log "eksctl is required but it's not installed. Aborting."; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { log "kubectl is required but it's not installed. Aborting."; exit 1; }
}

# Usage
usage() {
    echo "Usage: $(basename "$0") CLUSTER_NAME"
    echo "This script configures Amazon EKS Cluster with Metrics Server and OIDC Provider."
    echo
    echo "CLUSTER_NAME must be one of:"
    echo "  datascience-cluster"
    echo "  analytics-cluster"
    echo "  gateway-cluster"
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region to deploy resources"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  $(basename "$0") datascience-cluster"
    exit 1
}

# Setup kubectl context
setup_kubectl_context() {
    local cluster_name="$1"

    log "Setting up kubectl context for cluster: $cluster_name"
    
    if ! aws eks update-kubeconfig --name "$cluster_name"; then
        log "Error: Failed to update kubeconfig for cluster $cluster_name"
        return 1
    fi
    
    if ! kubectl get nodes &>/dev/null; then
        log "Error: Failed to connect to cluster $cluster_name"
        return 1
    fi
    
    log "Successfully connected to cluster: $cluster_name"
}

# Associate IAM OIDC Provider
associate_iam_oidc_provider() {
  local cluster_name="$1"
  eksctl utils associate-iam-oidc-provider --cluster "$cluster_name" --approve
}

# Deploy Metrics Server
deploy_metrics_server() {
    log "Deploying Metrics Server for cluster..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

    log "Metrics Server has been deployed for cluster."
}

# Main function
main() {
    local cluster_name="$1"

    log "EKS Post-Setup Configuration started on: $cluster_name"
    setup_kubectl_context "$cluster_name"
    associate_iam_oidc_provider "$cluster_name"
    deploy_metrics_server 

    log "EMR on EKS Virtual Cluster setup completed for cluster: $cluster_name"
}

##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##
# Start the main function with all the provided arguments
##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##

# Check for correct number of arguments
if [ $# -ne 1 ]; then
    usage
fi

# Check for required tools
check_dependencies

# No AWS CLI Output Paginated Output
export AWS_PAGER=""

# Check for required environment variables
[[ -z "${AWS_REGION}" ]] && { log "Error: AWS_REGION is not set." >&2; exit 1; }
log "AWS Region: $AWS_REGION"

# Call Main 
main "$1"
