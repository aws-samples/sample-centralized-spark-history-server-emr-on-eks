#!/usr/bin/env bash

# ~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~ #
#
# Script: deploy_shs.sh
# Description: This script deploys a Spark History Server on Amazon EKS using CloudFormation, bash and helm charts.
#
# ~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~...~ #

set -euo pipefail

# Constants
CFN_BUCKET_NAME_BASE="spark-history-server-cfn-templates"
S3_KEY_PREFIX="shs"
SHS_STACK_NAME="SHS-SparkHistoryServerStack"  
SHS_TEMPLATE_FILE="shs-stack.yaml"

SHS_CLUSTER_NAME="spark-history-server"
SHS_ECR_REPO_NAME="spark-history-server"
SHS_IMAGE_TAG="latest"
SHS_DOCKERFILE_PATH="$REPO_DIR/shs/Dockerfile"
SHS_CHART_PATH="$REPO_DIR/shs/chart"

NAMESPACE="spark-history"
SERVICE_ACCOUNT_NAME="spark-history-server-sa"
IRSA_ROLE_NAME="spark-history-server-irsa-role"

# VPC and S3 Bucket should exists already.
VPC_NAME="SHS-BaseInfraStack-VPC"
SPARK_LOGS_BUCKET_NAME_BASE="emr-spark-logs"
SPARK_LOGS_BUCKET_NAME_PREFIX="/spark-events"

# Global Variables
AWS_ACCOUNT_ID=""
CFN_BUCKET_NAME=""
VPC_ID=""
PUBLIC_SUBNETS=""
PRIVATE_SUBNETS=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "This script deploys a Spark History Server on Amazon EKS using CloudFormation."
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION                The AWS region to deploy resources in"
    echo "  REPO_DIR                  The directory containing the CloudFormation templates and scripts"
    echo
    echo "Example:"
    echo "  # Deploy with minimal configuration:"
    echo "  export AWS_REGION=us-west-2"
    echo "  export REPO_DIR=/path/to/repo"
    echo "  ./$(basename "$0")"
    exit 1
}

#--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--
# Deploy core infrastructure
#--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--

# Account Id
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

    if [ -z "$AWS_ACCOUNT_ID" ]; then
        log "Error: Failed to get the AWS_ACCOUNT_ID"
        return 1
    fi
}

# Get OIDC Provider URL for EKS cluster
get_oidc_provider() {
    local cluster_name=$1
    OIDC_PROVIDER=$(aws eks describe-cluster \
        --name "$cluster_name" \
        --query "cluster.identity.oidc.issuer" \
        --output text | sed 's|https://||')
    log "OIDC Provider URL: $OIDC_PROVIDER"
}

# Set kubectl context
set_cluster_context() {
    local cluster_name="${1}"
    local cluster_context_name="arn:aws:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${cluster_name}"

    if [ -z "${cluster_name}" ]; then
        log "Error: Cluster name is required"
        log "Usage: set_cluster_context <cluster-name>"
        return 1
    fi

    # Check if cluster exists in AWS
    if ! aws eks describe-cluster --name "${cluster_name}" >/dev/null 2>&1; then
        log "Cluster ${cluster_name} does not exist in AWS"
        return 0
    fi

    log "Setting kubectl context to cluster: ${cluster_context_name}"
    kubectl config use-context "${cluster_context_name}"
    
    if [ $? -eq 0 ]; then
        log "Successfully switched context to: ${cluster_context_name}"
        log "Current context: $(kubectl config current-context)"
    else
        log "Failed to switch context to: ${cluster_context_name}"
        log "Available contexts:"
        kubectl config get-contexts
        return 1
    fi
}

# Update kubeconfig connection details (local)
update_kubeconfig() {
    local cluster_name=$1

    if [ -z "${cluster_name}" ]; then
        echo "Error: Cluster name is required"
        echo "Usage: update_kubeconfig <cluster-name>"
        return 1
    fi

    echo "Checking if cluster ${cluster_name} exists in region ${AWS_REGION}..."
    if ! aws eks describe-cluster --name "${cluster_name}" --region "${AWS_REGION}" >/dev/null 2>&1; then
        echo "Cluster ${cluster_name} does not exist in region ${AWS_REGION}"
        return 0
    fi

    echo "Updating kubeconfig for cluster: ${cluster_name}"
    aws eks update-kubeconfig \
        --name "${cluster_name}" \
        --region "${AWS_REGION}" || \
        { echo "Error: Failed to update kubeconfig for cluster ${cluster_name}"; return 1; }

    # Verify the connection
    if kubectl get svc >/dev/null 2>&1; then
        echo "Successfully updated kubeconfig and verified connection to cluster ${cluster_name}"
        echo "Current context: $(kubectl config current-context)"
    else
        echo "Warning: Updated kubeconfig but unable to verify connection to cluster"
        return 1
    fi
}

# Network details
get_network_details() {
    # VPC
    VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query "Vpcs[0].VpcId" \
    --output text)

    if [ -z "$VPC_ID" ]; then
        log "Error: Failed to get the VPC_ID"
        return 1
    fi

    # Public Subnet
    PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
        --filters \
            "Name=vpc-id,Values=$VPC_ID" \
            "Name=tag:Name,Values=*Public*" \
        --query "Subnets[].SubnetId" \
        --output text | tr '\t' ',')

    if [ -z "$PUBLIC_SUBNETS" ]; then
        log "Error: Failed to get the PUBLIC_SUBNETS"
        return 1
    fi

    # Private Subnet
    PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters \
        "Name=vpc-id,Values=$VPC_ID" \
        "Name=tag:Name,Values=*Private*" \
    --query "Subnets[].SubnetId" \
    --output text | tr '\t' ',')

    if [ -z "$PRIVATE_SUBNETS" ]; then
        log "Error: Failed to get the PRIVATE_SUBNETS"
        return 1
    fi
}

# Get certificate ARN from SSL stack
get_certificate_arn() {
    log "Getting certificate ARN from SSL stack..."
    
    CERTIFICATE_ARN=$(aws cloudformation describe-stacks \
        --stack-name "SSL-Stack" \
        --query "Stacks[0].Outputs[?OutputKey=='CertificateArn'].OutputValue" \
        --output text)
    
    if [ -z "$CERTIFICATE_ARN" ] || [ "$CERTIFICATE_ARN" == "None" ]; then
        log "Error: Failed to get certificate ARN from SSL stack"
        return 1
    fi
    
    log "Certificate ARN: $CERTIFICATE_ARN"
}

# Create Parameter Json file from template for deploying AWS CloudFormation
create_parameter_json() {
    # Create parameters.json
    jq --arg vpc "$VPC_ID" \
       --arg subnets "$PRIVATE_SUBNETS" \
       '(.[] | select(.ParameterKey == "VpcId").ParameterValue) |= $vpc | 
        (.[] | select(.ParameterKey == "PrivateSubnets").ParameterValue) |= $subnets' \
       "$REPO_DIR/shs/cloudformation/parameters.tpl" > "$REPO_DIR/shs/cloudformation/parameters.json"

    log "Generated parameters.json with:"
    log "VPC ID: $VPC_ID"
    log "Private Subnets: $PRIVATE_SUBNETS"
}

# Upload AWS CloudFormation templates to S3 bucket
upload_templates() {
    log "Uploading CloudFormation templates..."
    # Upload file
    aws s3 cp "${REPO_DIR}/shs/cloudformation/${SHS_TEMPLATE_FILE}" "s3://${CFN_BUCKET_NAME}/cloudformation/${S3_KEY_PREFIX}/" || { log "Error: Failed to upload ${SHS_TEMPLATE_FILE}."; return 1; }
    log "Uploaded ${SHS_TEMPLATE_FILE}"
}

# Deploy Spark History Server stack
deploy_main_stack() {
    log "Deploying Spark History Server Cloudformation stack ..."

    if aws cloudformation describe-stacks --stack-name "${SHS_STACK_NAME}" >/dev/null 2>&1; then
        log "Stack ${SHS_STACK_NAME} already exists. Skipping create-stack ..."
    else
        aws cloudformation create-stack \
            --stack-name "${SHS_STACK_NAME}" \
            --disable-rollback \
            --template-url "https://${CFN_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/cloudformation/${S3_KEY_PREFIX}/${SHS_TEMPLATE_FILE}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameters "file://$REPO_DIR/shs/cloudformation/parameters.json" || { log "Error: Failed to create the stack."; return 1; }
        log "Creating stack: ${SHS_STACK_NAME}"
    fi

    aws cloudformation wait stack-create-complete --stack-name "${SHS_STACK_NAME}" 2>/dev/null || \
    aws cloudformation wait stack-update-complete --stack-name "${SHS_STACK_NAME}" || \
    { log "Error: Stack creation/update failed or timed out."; return 1; }

    log "Spark History Server Cloudformation stack deployment completed successfully"
}

# Update pre-existing IAM role trust policy with OIDC provider
update_role_trust_policy() {
    local cluster_name=$1
    
    # Get OIDC provider
    get_oidc_provider "$cluster_name"
    
    log "Updating trust policy for Spark History Server role: $IRSA_ROLE_NAME"
    
    # Create trust policy JSON for Spark History Server role
    TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

    echo "$IRSA_ROLE_NAME"
    echo "$TRUST_POLICY"
    
    # Update the role's trust policy
    if aws iam update-assume-role-policy \
        --role-name "$IRSA_ROLE_NAME" \
        --policy-document "$TRUST_POLICY"; then
        log "Successfully updated trust policy for role: $IRSA_ROLE_NAME"
    else
        log "Error: Failed to update trust policy for role: $IRSA_ROLE_NAME"
        return 1
    fi
}

#--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--
# Build and Push Spark History Server Image and Helm chart to Amazon ECR
#--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--

# Login to ECR
login_to_ecr() {
    log "Logging into ECR..."
    aws ecr get-login-password | finch login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
}

# Build and push Docker image to ECR
build_and_push_shs_image() {
    log "Building Docker image..."
    finch build -t "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$SHS_ECR_REPO_NAME:$SHS_IMAGE_TAG" \
    --platform linux/amd64 -f "$SHS_DOCKERFILE_PATH" .

    log "Pushing Docker image to ECR..."
    finch push "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$SHS_ECR_REPO_NAME:$SHS_IMAGE_TAG"
}

# Push Helm chart to ECR
push_shs_helm_chart() {

    aws ecr get-login-password \
    --region "${AWS_REGION}" | \
    helm registry login \
    --username AWS \
    --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

    local chart_url="oci://$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

    log "Packaging Helm chart..."
    helm package "$SHS_CHART_PATH" --destination "$REPO_DIR/tmp"

    log "Logging into ECR..."
    aws ecr get-login-password --region "${AWS_REGION}" | \
        helm registry login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

    log "Pushing Helm chart to ECR..."
    helm push "$(ls "$REPO_DIR"/tmp/*.tgz)" "$chart_url" --debug
}

#--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--
# Deploy Kubernetes Objects
#--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--

# Create Namespace for SHS
# With a manifest, kubectl apply is idempotent
create_namespace() {
  kubectl apply -f namespace.yaml
}

# Create Kubernetes Service Account
create_k8s_service_account() {
    if kubectl create serviceaccount "$SERVICE_ACCOUNT_NAME" \
        --namespace "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -; then
        echo "Successfully created service account $SERVICE_ACCOUNT_NAME in namespace $NAMESPACE"
        return 0
    else
        echo "Error: Failed to create service account $SERVICE_ACCOUNT_NAME" >&2
        return 1
    fi
}

# Annotate Service Account with IAM Role
annotate_service_account() {
    ROLE_ARN=$(aws iam get-role \
        --role-name "$IRSA_ROLE_NAME" \
        --query 'Role.Arn' \
        --output text)
    if [ -z "$ROLE_ARN" ]; then
        log "Error: Failed to get ARN for role $IRSA_ROLE_NAME"
        return 1
    fi
    
    if kubectl annotate serviceaccount "$SERVICE_ACCOUNT_NAME" \
        -n "$NAMESPACE" \
        eks.amazonaws.com/role-arn="$ROLE_ARN" \
        --overwrite; then
        echo "Successfully annotated service account $SERVICE_ACCOUNT_NAME with role ARN"
        return 0
    else
        echo "Error: Failed to annotate service account $SERVICE_ACCOUNT_NAME" >&2
        return 1
    fi
}

# Deploy Metrics Server required for HPA
deploy_metrics_server() {
    log "Deploying Metrics Server for cluster..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

    log "Metrics Server has been deployed for cluster."
}

# Acssociate IAM OIDS Provider 
associate_iam_oidc_provider() {
    local cluster_name=$1

    if [ -z "${cluster_name}" ]; then
        echo "Error: Cluster name is required"
        echo "Usage: create_oidc_provider <cluster-name>"
        return 1
    fi

    # Check if cluster exists
    if ! aws eks describe-cluster --name "${cluster_name}" --region "${AWS_REGION}" >/dev/null 2>&1; then
        echo "Cluster ${cluster_name} does not exist in region ${AWS_REGION}"
        return 0
    fi

    echo "Creating/associating OIDC provider for cluster: ${cluster_name}"
    eksctl utils associate-iam-oidc-provider \
        --region="${AWS_REGION}" \
        --cluster="${cluster_name}" \
        --approve || \
        { echo "Error: Failed to create/associate OIDC provider for cluster ${cluster_name}"; return 1; }

    echo "Successfully created/associated OIDC provider for cluster ${cluster_name}"
    return 0
}

# Install AWS Load Balancer Controller using Helm
deploy_aws_load_balancer_controller() {
  log "ALB deployment is initiated ..."
  local policy_name="AWSLoadBalancerControllerIAMPolicy"

  # Create AWSLoadBalancerControllerIAMPolicy
  # Check if policy exists
  local existing_policy_arn_1=$(aws iam list-policies --query "Policies[?PolicyName=='${policy_name}-part1'].Arn" --output text)

  if [ -z "$existing_policy_arn_1" ]; then
      log "Policy ${policy_name}-part1 does not exist. Creating..."

      # Variable replacement
      sed -e "s/\${AWS_ACCOUNT_ID}/$AWS_ACCOUNT_ID/g" -e "s/\${AWS_REGION}/$AWS_REGION/g" iam_policy_1.tpl > iam_policy_1.json

      # Create policy if it doesn't exist
      aws_lb_controller_policy_arn_1=$(aws iam create-policy \
          --policy-name "${policy_name}-part1" \
          --policy-document file://iam_policy_1.json \
          --query 'Policy.Arn' \
          --output text)
  else
      # If policy already exists, retrieve its ARN
      aws_lb_controller_policy_arn_1="$existing_policy_arn_1"
  fi

  local existing_policy_arn_2=$(aws iam list-policies --query "Policies[?PolicyName=='${policy_name}-part2'].Arn" --output text)

  if [ -z "$existing_policy_arn_2" ]; then
      log "Policy ${policy_name}-part2 does not exist. Creating..."

      # Variable replacement
      sed -e "s/\${AWS_ACCOUNT_ID}/$AWS_ACCOUNT_ID/g" -e "s/\${AWS_REGION}/$AWS_REGION/g" iam_policy_2.tpl > iam_policy_2.json

      # Create policy if it doesn't exist
      aws_lb_controller_policy_arn_2=$(aws iam create-policy \
          --policy-name "${policy_name}-part2" \
          --policy-document file://iam_policy_2.json \
          --query 'Policy.Arn' \
          --output text)
  else
      # If policy already exists, retrieve its ARN
      aws_lb_controller_policy_arn_2="$existing_policy_arn_2"
  fi

  # Create IRSA 
  # Check if IAM service account exists
  if ! aws iam get-role --role-name AmazonEKSLoadBalancerControllerRole &> /dev/null; then
      # Create IRSA only if the role doesn't exist
      eksctl create iamserviceaccount \
      --cluster="${SHS_CLUSTER_NAME}" \
      --namespace=kube-system \
      --name=aws-load-balancer-controller \
      --role-name AmazonEKSLoadBalancerControllerRole \
      --attach-policy-arn="${aws_lb_controller_policy_arn_1}" \
      --attach-policy-arn="${aws_lb_controller_policy_arn_2}" \
      --approve
  fi

  # Configure Helm repo
  helm repo add eks https://aws.github.io/eks-charts || true
  helm repo update eks
  
  # Install aws-load-balancer-controller chart
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$SHS_CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name="aws-load-balancer-controller" \
    --set vpcId="$VPC_ID" \
    --set region="$AWS_REGION"
  echo "ALB deployment is completed."
}

# Create values-shs.yaml and values.yaml
create_values_shs_yaml() {

    local fully_qualified_shs_ecr_repo_name="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$SHS_ECR_REPO_NAME"

    yq eval "
    .s3.bucket.name = \"$SPARK_LOGS_BUCKET_NAME\" |
    .s3.bucket.prefix = \"$SPARK_LOGS_BUCKET_NAME_PREFIX\" |
    .image.repository = \"$fully_qualified_shs_ecr_repo_name\" |
    .ingress.annotations.\"alb.ingress.kubernetes.io/subnets\" = \"$PRIVATE_SUBNETS\" |
    .ingress.annotations.\"alb.ingress.kubernetes.io/certificate-arn\" = \"$CERTIFICATE_ARN\"
    " "$REPO_DIR/shs/chart/values-shs.tpl" > "$REPO_DIR/shs/chart/values-shs.yaml"

}

# Wait for ws-load-balancer-controller to be ready
wait_for_alb_controller() {
    echo "Waiting for AWS Load Balancer Controller to be ready..."
    kubectl wait deployment -n kube-system aws-load-balancer-controller --for=condition=available --timeout=300s || \
        { echo "Error: Timeout waiting for AWS Load Balancer Controller"; return 1; }
    
    echo "AWS Load Balancer Controller is ready"
}


# Deploy Spark History Server
deploy_shs() {
    # Registry login
    aws ecr get-login-password | helm registry login \
        --username AWS \
        --password-stdin  "${AWS_ACCOUNT_ID}".dkr.ecr."${AWS_REGION}".amazonaws.com

    # Deploy with helm
    helm upgrade --install --wait spark-history-server \
                 --timeout 15m0s \
                 --version 3.1.1-2 \
                 --namespace "${NAMESPACE}" \
                 --create-namespace oci://"${AWS_ACCOUNT_ID}".dkr.ecr."${AWS_REGION}".amazonaws.com/spark-history-server \
                 -f "${REPO_DIR}/shs/chart/values.yaml" \
                 -f "${REPO_DIR}/shs/chart/values-shs.yaml"
}

# Main function
main() {
  log "Configuring Spark History Server on Amazon EKS cluster ..."
  
  #--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--
  # Deploy core infrastructure
  #--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--

  # Account Id
  get_account_id

  # S3 Bucket Names
  CFN_BUCKET_NAME="${CFN_BUCKET_NAME_BASE}-${AWS_ACCOUNT_ID}-${AWS_REGION}"
  SPARK_LOGS_BUCKET_NAME="${SPARK_LOGS_BUCKET_NAME_BASE}-${AWS_ACCOUNT_ID}-${AWS_REGION}"

  # Network Details
  get_network_details

  # Create Parameters File
  create_parameter_json

  # Upload templates
  upload_templates

  # Deploy Stack
  deploy_main_stack

  # Acssociate IAM OIDC Provider 
  associate_iam_oidc_provider "$SHS_CLUSTER_NAME"

  # Get OIDC provider 
  get_oidc_provider "$SHS_CLUSTER_NAME"

  # Update IAM role with OIDC trust relationship
  update_role_trust_policy "$SHS_CLUSTER_NAME"

  #--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--
  # Build and Push Spark History Server Image and Helm chart to Amazon ECR
  #--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--

  # Login to ECR
  login_to_ecr

  # Build and push Docker image to ECR
  build_and_push_shs_image

  # Push Helm chart to ECR
  push_shs_helm_chart

  #--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--
  # Deploy Kubernetes Objects
  #--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--

  # Update kubeconfig connection details (local)
  update_kubeconfig "$SHS_CLUSTER_NAME"

  # Set kubectl context for Spark History Server
  set_cluster_context "$SHS_CLUSTER_NAME"

  # Create Namespace
  create_namespace

  # Create Kubernetes Service Account
  create_k8s_service_account

  # Annotate Service Account with IAM Role
  annotate_service_account

  # Deploy Metrics Server for HPA
  deploy_metrics_server

  # Deploy AWS LoadBalancer Controller
  deploy_aws_load_balancer_controller

  # Wait for ws-load-balancer-controller to be ready
  wait_for_alb_controller

  # Get certificate arn
  get_certificate_arn

  # Create values-shs.yaml
  create_values_shs_yaml

  # Deploy Spark History Server
  deploy_shs

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
command -v finch >/dev/null 2>&1 || { log "Docker is required but it's not installed. Aborting."; exit 1; }
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
