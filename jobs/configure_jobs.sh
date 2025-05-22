set -euo pipefail

# =====================================================================================
# This script configures and sets up the Spark History Server environment by preparing
# necessary resources and configurations for multiple EMR clusters.
#
# Key functionalities include:
# - Creating and configuring S3 bucket for Spark history logs
# - Uploading Spark application files to S3
# - Generating Spark job manifests for multiple clusters
# - Configuring environment for both datascience and analytics clusters
#
# The script handles:
# - S3 bucket management for Spark logs
# - Spark application file deployment
# - Manifest file generation for different clusters
# - AWS account and region-specific configurations
#
# Required environment variables:
# AWS_REGION - The AWS region where resources will be created
# REPO_DIR   - The directory containing templates and supporting files
#
# Prerequisites:
# - AWS CLI installed and configured
# - Appropriate AWS permissions
# - Required template files in REPO_DIR
#
# To execute:
# export AWS_REGION=us-west-2
# export REPO_DIR=/path/to/repository
# ./configure_jobs.sh
# =====================================================================================

# Constants
S3_BUCKET_NAME_PREFIX="emr-spark-logs"
SPARK_APP_FILE="spark_history_demo.py"
SPARK_JOB_NAME_PREFIX="start-job-run-demo"  
IAM_ROLE_NAME_FOR_JOB_EXECUTION="EmrOnEKSSparkJobExecutionRole"

EMR_RELEASE_LABEL="emr-7.2.0_custom"
EMR_REPO_NAME="emr-7.2.0_custom" 
EMR_IMAGE_TAG="latest"
EMR_DOCKERFILE_PATH="$REPO_DIR/jobs/Dockerfile"

# Globals 
S3_BUCKET_NAME=""
VIRTUAL_CLUSTER_ID=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "Configures and sets up the Spark History Server environment by preparing necessary"
    echo "resources and configurations for multiple EMR clusters. This script handles S3 bucket"
    echo "creation, Spark application file uploads, and manifest generation for different clusters."
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region where resources will be deployed (e.g., us-west-2)"
    echo "  REPO_DIR      The directory containing templates and supporting files"
    echo
    echo "Prerequisites:"
    echo "  - AWS CLI installed and configured with appropriate permissions"
    echo "  - Required template files present in REPO_DIR/infra/cloudformation/"
    echo "  - Proper AWS credentials and permissions"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  export REPO_DIR=/path/to/repository"
    echo "  ./$(basename "$0")"
    exit 1
}

# Get Account Id
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    log "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Upload Spark Application File to S3
upload_spark_app_file_to_s3() {
    log "Upload Spark Application file: ${SPARK_APP_FILE}"

    aws s3 cp "${SPARK_APP_FILE}" "s3://${S3_BUCKET_NAME}/app/${SPARK_APP_FILE}"
    log "Uploaded Spark Hive Example App File to S3"
}


# Get EMR on EKS Virtual Cluster ID by name
get_emr_virtual_cluster_id() {
    local cluster_name="$1"
    local virtual_cluster_id
    
    # Get the virtual cluster ID
    virtual_cluster_id=$(aws emr-containers list-virtual-clusters \
        --query "virtualClusters[?name=='${cluster_name}' && state=='RUNNING'].id" \
        --output text)

    # Check if cluster ID was found
    if [ -z "$virtual_cluster_id" ]; then
        echo "Error: No running virtual cluster found with name: $cluster_name"
        return 1
    fi

    echo "$virtual_cluster_id"
}

# Custom Amazon EMR on EKS Image with DatFlint - Start 

# Pull EMR on EKS Base Image
pull_base_emr_image() {
    # Login
    aws ecr-public get-login-password --region us-east-1 | finch login --username AWS --password-stdin public.ecr.aws
    # Pull
    finch pull public.ecr.aws/emr-on-eks/spark/emr-7.2.0:20241010
}

# Login to ECR
login_to_ecr() {
    log "Logging into ECR..."
    aws ecr get-login-password | finch login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
}

# Build Custom Image and Puch to ECR
build_and_push_emr_image() {
    log "Building EMR custom Docker image..."
    finch build -t "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$EMR_REPO_NAME:$EMR_IMAGE_TAG" \
    --platform linux/amd64 -f "$EMR_DOCKERFILE_PATH" .

    log "Pushing EMR Docker image to ECR..."
    finch push "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$EMR_REPO_NAME:$EMR_IMAGE_TAG"
}

# Custom Amazon EMR on EKS Image with DatFlint - End

# Generate  Spark Operator manifest file for Spark Operator
generate_spark_operator_manifest(){

    # Variable in caps despite being local for regex match in the .tpl file
    local CLUSTER_NAME=$1

    local template_file="${REPO_DIR}/jobs/spark-operator/spark-history-demo.tpl"
    local output_file="${REPO_DIR}/jobs/spark-operator/spark-history-demo-${CLUSTER_NAME}.yaml"
    
    # Create Manifest files
    while IFS= read -r line; do
        # Escape existing double quotes in the line
        escaped_line="${line//\"/\\\"}"
        eval "printf '%s\n' \"$escaped_line\"" 
    done < "$template_file" > "$output_file"

    if [ ! -f "$output_file" ]; then
        echo "Error: Failed to generate manifest file"
        return 1
    fi
    log "Generated Spark Job manifest: $output_file"
}

# Generate StartRunJob JSON file
generate_start_run_job_json(){
    local CLUSTER_NAME=$1
    local VIRTUAL_CLUSTER_ID=$(get_emr_virtual_cluster_id "$CLUSTER_NAME")
    local SPARK_JOB_NAME="${SPARK_JOB_NAME_PREFIX}-${CLUSTER_NAME}"
    local IAM_ROLE_ARN_FOR_JOB_EXECUTION="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME_FOR_JOB_EXECUTION}"

    local template_file="${REPO_DIR}/jobs/start-job-run/start-job-run-request.tpl"
    local output_file="${REPO_DIR}/jobs/start-job-run/start-job-run-request-${CLUSTER_NAME}.json"

    # Process JSON template with jq
    jq --arg job_name "$SPARK_JOB_NAME" \
       --arg cluster_id "$VIRTUAL_CLUSTER_ID" \
       --arg role_arn "$IAM_ROLE_ARN_FOR_JOB_EXECUTION" \
       --arg s3_bucket "$S3_BUCKET_NAME" \
       --arg account_id "$AWS_ACCOUNT_ID" \
       --arg region "$AWS_REGION" \
       --arg repo_name "$EMR_REPO_NAME" \
       --arg image_tag "$EMR_IMAGE_TAG" \
       '.name = $job_name | 
        .virtualClusterId = $cluster_id |
        .executionRoleArn = $role_arn |
        .jobDriver.sparkSubmitJobDriver.entryPoint = "s3://\($s3_bucket)/app/spark_history_demo.py" |
        .jobDriver.sparkSubmitJobDriver.entryPointArguments = [
            "--input-path",
            "s3://\($s3_bucket)/data/input",
            "--output-path",
            "s3://\($s3_bucket)/data/output"
        ] |
        .configurationOverrides.applicationConfiguration[0].properties["spark.kubernetes.container.image"] = "\($account_id).dkr.ecr.\($region).amazonaws.com/\($repo_name):\($image_tag)" |
        .configurationOverrides.applicationConfiguration[0].properties["spark.app.name"] = $job_name |
        .configurationOverrides.applicationConfiguration[0].properties["spark.eventLog.enabled"] = "true" |
        .configurationOverrides.applicationConfiguration[0].properties["spark.eventLog.dir"] = "s3://\($s3_bucket)/spark-events/" |
        .configurationOverrides.monitoringConfiguration.s3MonitoringConfiguration.logUri = "s3://\($s3_bucket)/spark-events/"' \
       "$template_file" > "$output_file"

    if [ ! -f "$output_file" ]; then
        echo "Error: Failed to generate manifest file"
        return 1
    fi
    log "Generated Spark Job manifest: $output_file"
}

# Main function
main() {
    log "Setup script execution initiated..."

    # Get Account ID
    get_account_id

    # Bucket Name 
    S3_BUCKET_NAME="${S3_BUCKET_NAME_PREFIX}-${AWS_ACCOUNT_ID}-${AWS_REGION}"

    # Upload Spark Application File to S3
    upload_spark_app_file_to_s3

    # EMR on EKS Custom Image - Start 

    # Pull EMR on EKS Base Image
    pull_base_emr_image
    # Login to ECR
    login_to_ecr
    # Build Custom Image and Puch to ECR
    build_and_push_emr_image

    # EMR on EKS Custom Image - End 

    # Generate Spark Operator Manifest file for datascience-cluster
    generate_spark_operator_manifest "datascience-cluster-v"

    # Generate Spark Operator Manifest file for analytics-cluster
    generate_spark_operator_manifest "analytics-cluster-v"

    # Generate Spark StartRunJob JSON file for datascience-cluster
    generate_start_run_job_json "datascience-cluster-v"

    # Generate StartRunJob JSON file for analytics-cluster
    generate_start_run_job_json "analytics-cluster-v"

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

[[ -z "${REPO_DIR:-}" ]] && { log "Error: REPO_DIR is not set." >&2; exit 1; }
log "Repo Directory: $REPO_DIR"

# Call Main 
main
