#!/usr/bin/env bash

# =====================================================================================
#
# This script deploys AWS Client VPN endpoint and required resources.
# The deployment is performed in the following order:
# 1. Generate server and client certificates using Easy-RSA
# 2. Import certificates to AWS Certificate Manager (ACM)
# 3. Upload CloudFormation templates to S3
# 4. Deploy VPN CloudFormation stack
# 5. Download and prepare VPN client configuration file
#
# Note: Requires existing VPC and subnets from SHS-BaseInfraStack
#
# =====================================================================================

set -euo pipefail

# Constants
CFN_BUCKET_NAME_BASE="spark-history-server-cfn-templates"
S3_KEY_PREFIX="vpn"
VPN_STACK_NAME="SHS-VPNStack"
VPN_TEMPLATE_FILE="vpn-stack.yaml"
EASYRSA_REPO="https://github.com/OpenVPN/easy-rsa.git"
SERVER_NAME="shs-vpn-server"
CERT_DIR="client_vpn_certs"
CLIENT_NAME="shs-vpn-client"

# VPC should exists already.
VPC_NAME="SHS-BaseInfraStack-VPC"

# Global Variables
AWS_ACCOUNT_ID=""
SERVER_CERT_ARN=""
CFN_BUCKET_NAME=""
VPC_ID=""
PRIVATE_SUBNETS=""
VPC_CIDR=""
DNS_IP=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "This script generates OpenVPN certificates and uploads them to ACM."
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region to create resources in"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  export REPO_DIR=/path/to/repository"
    echo "  ./$(basename "$0")"
    exit 1
}

# Account Id
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

    if [ -z "$AWS_ACCOUNT_ID" ]; then
        log "Error: Failed to get the AWS_ACCOUNT_ID"
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

# Get VPC CIDR and calculate DNS IP
get_vpc_cidr_and_dns() {
    # Get VPC CIDR
    VPC_CIDR=$(aws ec2 describe-vpcs \
    --vpc-ids "$VPC_ID" \
    --query "Vpcs[0].CidrBlock" \
    --output text)

    if [ -z "$VPC_CIDR" ]; then
        log "Error: Failed to get the VPC CIDR"
        return 1
    fi
    
    # Calculate DNS IP (typically at base CIDR + 2 in AWS VPCs)
    # For example, if VPC CIDR is 10.0.0.0/16, DNS IP is 10.0.0.2
    local ip_parts=($(echo "$VPC_CIDR" | cut -d'/' -f1 | tr '.' ' '))
    DNS_IP="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.$((${ip_parts[3]} + 2))"
    
    log "VPC CIDR: $VPC_CIDR"
    log "Calculated DNS IP: $DNS_IP"
}

create_parameter_json() {
    # Create parameters.json
    jq --arg vpc "$VPC_ID" \
       --arg subnets "$PRIVATE_SUBNETS" \
       --arg server_cert "$SERVER_CERT_ARN" \
       --arg dns_ip "$DNS_IP" \
       '(.[] | select(.ParameterKey == "VpcId").ParameterValue) |= $vpc |
        (.[] | select(.ParameterKey == "DnsServerIp").ParameterValue) |= $dns_ip |
        (.[] | select(.ParameterKey == "SubnetIds").ParameterValue) |= $subnets |
        (.[] | select(.ParameterKey == "ServerCertificateArn").ParameterValue) |= $server_cert |
        (.[] | select(.ParameterKey == "ClientCertificateArn").ParameterValue) |= $server_cert' \
       "${REPO_DIR}/vpn/cloudformation/parameters.tpl" > "${REPO_DIR}/vpn/cloudformation/parameters.json"

    log "Generated parameters.json with:"
    log "VPC ID: $VPC_ID"
    log "DNS IP: $DNS_IP"
    log "Private Subnets: $PRIVATE_SUBNETS"
    log "Certificate ARN: $SERVER_CERT_ARN"
}

# Upload AWS CloudFormation templates to S3 bucket
upload_templates() {
    log "Uploading CloudFormation templates..."
    
    # Set the CFN bucket name
    CFN_BUCKET_NAME="${CFN_BUCKET_NAME_BASE}-${AWS_ACCOUNT_ID}-${AWS_REGION}"

    # Check if bucket exists, if not create it
    if ! aws s3 ls "s3://${CFN_BUCKET_NAME}" 2>&1 > /dev/null; then
        log "Creating S3 bucket: ${CFN_BUCKET_NAME}"
        aws s3 mb "s3://${CFN_BUCKET_NAME}" --region "${AWS_REGION}" || { log "Error: Failed to create bucket."; return 1; }
    fi

    # Upload VPN stack template
    aws s3 cp "${REPO_DIR}/vpn/cloudformation/${VPN_TEMPLATE_FILE}" "s3://${CFN_BUCKET_NAME}/cloudformation/${S3_KEY_PREFIX}/" || { log "Error: Failed to upload ${VPN_TEMPLATE_FILE}."; return 1; }
    log "Uploaded ${VPN_TEMPLATE_FILE}"
}

# Deploy VPN stack
deploy_main_stack() {
    log "Deploying VPN Cloudformation stack..."

    if aws cloudformation describe-stacks --stack-name "${VPN_STACK_NAME}" >/dev/null 2>&1; then
        log "Stack ${VPN_STACK_NAME} already exists."
    else
        log "Creating new stack: ${VPN_STACK_NAME}"
        aws cloudformation create-stack \
            --stack-name "${VPN_STACK_NAME}" \
            --template-url "https://${CFN_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/cloudformation/${S3_KEY_PREFIX}/${VPN_TEMPLATE_FILE}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameters file://"${REPO_DIR}/vpn/cloudformation/parameters.json" || { log "Error: Failed to create the stack."; return 1; }
    fi

    aws cloudformation wait stack-create-complete --stack-name "${VPN_STACK_NAME}" 2>/dev/null || \
    aws cloudformation wait stack-update-complete --stack-name "${VPN_STACK_NAME}" || \
    { log "Error: Stack creation/update failed or timed out."; return 1; }

    log "VPN Cloudformation stack deployment completed successfully"
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

# Setup OpenVPN Easy-RSA
setup_easyrsa() {
    log "Setting up Easy-RSA environment..."
    
    # Create and move to working directory
    mkdir -p "${REPO_DIR}/vpn/${CERT_DIR}"
    cd "${REPO_DIR}/vpn/${CERT_DIR}" || { log "Error: Failed to change to working directory."; return 1; }

    # Clone Easy-RSA if not already present
    if [ ! -d "easy-rsa" ]; then
        if ! git clone "$EASYRSA_REPO"; then
            log "Error: Failed to clone Easy-RSA repository."
            return 1
        fi
    fi

    cd easy-rsa/easyrsa3 || { log "Error: Failed to change to easyrsa3 directory."; return 1; }

    # Initialize PKI
    if ! ./easyrsa init-pki; then
        log "Error: Failed to initialize PKI."
        return 1
    fi

    # Set up the vars using provided or default values
    export EASYRSA_REQ_COUNTRY="${1:-US}"
    export EASYRSA_REQ_PROVINCE="${2:-Washington}"
    export EASYRSA_REQ_CITY="${3:-Seattle}"
    export EASYRSA_REQ_ORG="${4:-AWS}"
    export EASYRSA_REQ_EMAIL="${5:-admin@example.com}"
    export EASYRSA_REQ_OU="${6:-IT}"
    export EASYRSA_BATCH="yes"

    log "Easy-RSA environment setup completed."
}

# Generate Certificates
generate_certificates() {
    log "Generating certificates..."

    # Build CA
    if ! ./easyrsa build-ca nopass; then
        log "Error: Failed to build CA."
        return 1
    fi

    # Generate server certificate
    if ! ./easyrsa --san="DNS:${SERVER_NAME}" build-server-full "${SERVER_NAME}" nopass; then
        log "Error: Failed to generate server certificate."
        return 1
    fi

    # Generate client certificate
    if ! ./easyrsa build-client-full "${CLIENT_NAME}" nopass; then
        log "Error: Failed to generate client certificate."
        return 1
    fi

    log "Certificates generated successfully."
}

# Copy Certificates
copy_certificates() {
    local CERT_PATH="${REPO_DIR}/vpn/${CERT_DIR}"
    log "Copying certificates to ${CERT_PATH}..."

    cp pki/ca.crt "${CERT_PATH}/"
    cp pki/issued/"${SERVER_NAME}".crt "${CERT_PATH}/"
    cp pki/private/"${SERVER_NAME}".key "${CERT_PATH}/"
    cp pki/issued/"${CLIENT_NAME}".crt "${CERT_PATH}/"
    cp pki/private/"${CLIENT_NAME}".key "${CERT_PATH}/"

    log "Certificates copied successfully."
}

# Import Certificates to ACM
import_certificates() {
    cd "${REPO_DIR}/vpn/${CERT_DIR}" || { log "Error: Failed to change to cert directory."; return 1; }
    
    log "Importing certificate to ACM..."
    
    # Import server certificate
    SERVER_CERT_ARN=$(aws acm import-certificate \
        --certificate fileb://"${SERVER_NAME}".crt \
        --private-key fileb://"${SERVER_NAME}".key \
        --certificate-chain fileb://ca.crt \
        --region "${AWS_REGION}" \
        --query 'CertificateArn' \
        --output text)

    if [ -z "$SERVER_CERT_ARN" ]; then
        log "Error: Failed to import server certificate."
        return 1
    fi

    log "Certificate imported successfully."
}

# Download and prepare VPN configuration file
download_vpn_config() {
    log "Downloading VPN configuration file..."
    
    # Get the Client VPN Endpoint ID from CloudFormation stack
    local vpn_endpoint_id=$(aws cloudformation describe-stacks \
        --stack-name "${VPN_STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`ClientVPNEndpointId`].OutputValue' \
        --output text)

    if [ -z "$vpn_endpoint_id" ]; then
        log "Error: Failed to get VPN endpoint ID"
        return 1
    fi

    # Download the configuration file
    local config_file="${REPO_DIR}/vpn/${CERT_DIR}/client-config.ovpn"
    aws ec2 export-client-vpn-client-configuration \
        --client-vpn-endpoint-id "$vpn_endpoint_id" \
        --output text > "$config_file" || { log "Error: Failed to download configuration file"; return 1; }

    log "Configuration file downloaded to: $config_file"
    return 0
}

# Prepare VPN configuration file with certificates
prepare_vpn_config() {
    log "Preparing VPN configuration file..."
    
    local config_file="${REPO_DIR}/vpn/${CERT_DIR}/client-config.ovpn"
    local client_cert="${REPO_DIR}/vpn/${CERT_DIR}/${CLIENT_NAME}.crt"
    local client_key="${REPO_DIR}/vpn/${CERT_DIR}/${CLIENT_NAME}.key"

    # Check if files exist
    if [ ! -f "$config_file" ] || [ ! -f "$client_cert" ] || [ ! -f "$client_key" ]; then
        log "Error: Required files are missing"
        return 1
    fi

    # Create temporary file
    local temp_file="${config_file}.tmp"
    cp "$config_file" "$temp_file"

    # Add certificate and key to config file
    echo "<cert>" >> "$temp_file"
    cat "$client_cert" >> "$temp_file"
    echo "</cert>" >> "$temp_file"
    echo "<key>" >> "$temp_file"
    cat "$client_key" >> "$temp_file"
    echo "</key>" >> "$temp_file"

    # Replace original file
    mv "$temp_file" "$config_file"

    log "VPN configuration file prepared successfully"
    return 0
}



# Main function
main() {
    log "Certificate generation process initiated..."

    # Get Account ID
    get_account_id
    
    # Network Details
    get_network_details

    # Get VPC CIDR and calculate DNS IP
    get_vpc_cidr_and_dns

    # Check if certificates exist in ACM
    if ! check_existing_certificates; then
        # NOTE: Update the following values if you want to create a cert with different values. 
        setup_easyrsa "US" "Washington" "Seattle" "AWS" "admin@example.com" "IT"
        generate_certificates 
        copy_certificates 
        import_certificates 
    fi

    # Create Parameters File
    create_parameter_json

    # Upload templates
    upload_templates

    # Deploy Stack
    deploy_main_stack

    # Download VPN configuration
    download_vpn_config

    # Prepare VPN configuration
    prepare_vpn_config

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
command -v git >/dev/null 2>&1 || { log "git is required but it's not installed. Aborting."; exit 1; }
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