#!/bin/bash

set -euo pipefail

# =====================================================================================
# This script automates the setup of Amazon EMR on EKS Virtual Clusters.
# 
# Key functionalities include:
# - Setting up kubectl context for the specified EKS cluster
# - Configuring necessary permissions for EMR on EKS
# - Logging into Amazon ECR
# - Installing/upgrading the Spark Operator using Helm
#
# Usage: ./script_name.sh CLUSTER_NAME
#
# Required environment variables:
# - AWS_REGION: The AWS region to deploy resources
# =====================================================================================

# Script variables
RELEASE_NAME="spark-operator-demo"
NAMESPACE="spark-operator"
CHART_VERSION="7.5.0"
SPARK_JOBS_NAMESPACE="emr"
ROLE_NAME="EmrOnEKSSparkJobExecutionRole"
 
IAM_ROLE_NAME="spark-history-server-irsa-role"
IAM_POLICY_NAME="spark-history-server-s3-policy"


# Globals 
AWS_ACCOUNT_ID=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Check Dependencies
check_dependencies() {
    command -v aws >/dev/null 2>&1 || { log "AWS CLI is required but it's not installed. Aborting."; exit 1; }
    command -v docker >/dev/null 2>&1 || { log "Docker is required but it's not installed. Aborting."; exit 1; }
    command -v helm >/dev/null 2>&1 || { log "Helm is required but it's not installed. Aborting."; exit 1; }
    command -v eksctl >/dev/null 2>&1 || { log "eksctl is required but it's not installed. Aborting."; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { log "kubectl is required but it's not installed. Aborting."; exit 1; }
}

# Usage
usage() {
    echo "Usage: $(basename "$0") CLUSTER_NAME"
    echo "This script sets up Amazon EMR on EKS cluster with Spark Operator."
    echo
    echo "CLUSTER_NAME must be one of:"
    echo "  datascience-cluster"
    echo "  analytics-cluster"
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region to deploy resources"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  $(basename "$0") datascience-cluster"
    exit 1
}

# Get Account Id
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    log "AWS Account ID: $AWS_ACCOUNT_ID"
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

# Sets up EMR on EKS permissions for the specified cluster
setup_emr_on_eks_permissions() {
    local cluster_name="$1"

    log "Setting up EMR on EKS permissions for cluster: $cluster_name"

    kubectl apply -f namespace.yaml
    kubectl apply -f role.yaml -f role-binding.yaml -f emr-containers-sa-spark-rbac.yaml

    local service_linked_role_arn
    if ! aws iam get-role --role-name AWSServiceRoleForAmazonEMRContainers >/dev/null 2>&1; then
        log "Creating AWSServiceRoleForAmazonEMRContainers service-linked role..."
        aws iam create-service-linked-role --aws-service-name emr-containers.amazonaws.com || true
    fi
    
    service_linked_role_arn=$(aws iam get-role --role-name AWSServiceRoleForAmazonEMRContainers --query 'Role.Arn' --output text)
    if [ -z "$service_linked_role_arn" ]; then
        log "Error: Failed to get AWSServiceRoleForAmazonEMRContainers ARN"
        return 1
    fi

    eksctl create iamidentitymapping \
        --cluster "$cluster_name" \
        --namespace "$SPARK_JOBS_NAMESPACE" \
        --service-name "emr-containers"

    eksctl create iamidentitymapping \
        --cluster "$cluster_name" \
        --arn "$service_linked_role_arn" \
        --username emr-containers

    log "Successfully set up EMR on EKS permissions for cluster: $cluster_name"
}

login_to_ecr() {

    log "Logging in to Public ECR registry"
    aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws

    if ! aws ecr-public get-login-password --region us-east-1 | \
        helm registry login --username AWS --password-stdin public.ecr.aws; then
        log "Error: Failed to login to public ECR registry"
        return 1
    fi

    log "Successfully logged in to ECR registry"
}

install_spark_operator() {
    
    local chart_url="oci://public.ecr.aws/emr-on-eks/spark-operator"

    log "Checking for existing Helm release ${RELEASE_NAME} in namespace ${NAMESPACE}"

    if helm ls -n "$NAMESPACE" | grep -q "$RELEASE_NAME"; then
        log "Helm release ${RELEASE_NAME} already exists. Upgrading..."
        if ! helm upgrade "$RELEASE_NAME" "$chart_url" \
            --set emrContainers.awsRegion="$AWS_REGION" \
            --set webhook.enable=true \
            --version "$CHART_VERSION" \
            --namespace "$NAMESPACE"; then
            log "Error: Failed to upgrade Helm release ${RELEASE_NAME}"
            return 1
        fi
    else
        log "Installing new Helm release ${RELEASE_NAME} in namespace ${NAMESPACE}"
        if ! helm install "$RELEASE_NAME" "$chart_url" \
            --set emrContainers.awsRegion="$AWS_REGION" \
            --set webhook.enable=true \
            --version "$CHART_VERSION" \
            --namespace "$NAMESPACE" \
            --create-namespace; then
            log "Error: Failed to install Helm release ${RELEASE_NAME}"
            return 1
        fi
    fi

    log "Successfully installed/upgraded Helm release ${RELEASE_NAME}"
}

# Create Secret for Service Account
create_secret() {
  kubectl apply -f spark-operator-sa-secret.yaml
}

# Attach Secret to Service Account
attach_secret_to_service_account() {
  kubectl patch serviceaccount emr-containers-sa-spark-operator -n spark-operator -p '{"secrets": [{"name": "emr-containers-sa-spark-operator-token"}]}'
}

# Associate IAM OIDC Provider
associate_iam_oidc_provider() {
  local cluster_name="$1"
  eksctl utils associate-iam-oidc-provider --cluster "$cluster_name" --approve
}

# Setup IRSA
create_irsa() {
    local cluster_name="$1"
    local role_name="$2"
    local role_arn=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)

    echo "Configuring IRSA for $cluster_name..."
    
    if ! eksctl create iamserviceaccount \
            --name emr-containers-sa-spark \
            --namespace emr \
            --cluster "$cluster_name" \
            --attach-role-arn "$role_arn" \
            --approve \
            --override-existing-serviceaccounts; then
        echo "Error: Failed to create IAM service account for ${cluster_name}."
        return 1
    fi
    
    echo "Successfully configured IRSA for $cluster_name."
}

# Create EMR on EKS clusters 
create_emr_on_eks_virtual_cluster() {
    local cluster_name="$1"
    local namespace="$2"
    local virtual_cluster_name="${cluster_name}-v"

    # Check if the virtual cluster already exists (CREATING or RUNNING state)
    echo "Checking if virtual cluster ${virtual_cluster_name} exists in region ${AWS_REGION}..."
    existing_virtual_cluster_id=$(aws emr-containers list-virtual-clusters --query "virtualClusters[?name=='${virtual_cluster_name}' && (state=='CREATING' || state=='RUNNING')] | [0].id" --output text)

    if [ "$existing_virtual_cluster_id" != "None" ]; then
        echo "Virtual cluster ${virtual_cluster_name} already exists with ID ${existing_virtual_cluster_id}."
        return 0
    else
        echo "Virtual cluster ${virtual_cluster_name} does not exist. Proceeding with creation..."
    fi

    echo "Creating EMR on EKS Virtual Cluster: ${virtual_cluster_name}"

    # Create the virtual cluster
    if ! aws emr-containers create-virtual-cluster \
        --name "${virtual_cluster_name}" \
        --container-provider "{
            \"id\": \"${cluster_name}\",
            \"type\": \"EKS\",
            \"info\": {
                \"eksInfo\": {
                    \"namespace\": \"${namespace}\"
                }
            }
        }"; then

        echo "Error: Failed to create EMR on EKS Virtual Cluster"
        return 1
    fi

    echo "Successfully created EMR on EKS Virtual Cluster: ${virtual_cluster_name}"
}

# Apply RBAC rules for Spark driver, granting necessary permissions in EMR on EKS environment
apply_spark_rbac() {
    log "Applying Spark RBAC rules"

    kubectl apply -f emr-containers-sa-spark-rbac.yaml
    kubectl apply -f spark-operator-emr-rbac.yaml
    
    log "Spark RBAC rules applied successfully"
}

# Main function
main() {
    local cluster_name="$1"

    log "EMR on EKS Virtual Cluster setup initiated for cluster: $cluster_name"
    
    setup_kubectl_context "$cluster_name"
    setup_emr_on_eks_permissions "$cluster_name"
    
    login_to_ecr
    install_spark_operator
    create_secret
    attach_secret_to_service_account
    associate_iam_oidc_provider "$cluster_name"
    create_irsa "$cluster_name" "$ROLE_NAME"
    create_emr_on_eks_virtual_cluster "$cluster_name" "$SPARK_JOBS_NAMESPACE"
    
    apply_spark_rbac

    log "EMR on EKS Virtual Cluster setup completed for cluster: $cluster_name"
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