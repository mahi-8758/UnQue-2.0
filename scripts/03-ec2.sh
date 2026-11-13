#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/03-ec2.sh
# Project: UnQue 2.0 - Campus Appointment Booking System
# Purpose: Provision one Ubuntu Server 24.04 LTS EC2 instance for the backend.
#
# Constraints & Architecture:
#   - Region: ap-south-1 (Mumbai)
#   - OS: Ubuntu Server 24.04 LTS (Noble Numbat), x86_64 (Canonical AMI)
#   - Instance Type: t3.micro (cost-conscious, orderable in ap-south-1)
#   - Subnet: Existing public subnet (10.20.1.0/24, MapPublicIpOnLaunch=true)
#   - Security Group: Existing unque-ec2-sg (SSH port 22, API port 5001)
#   - Key Pair: unque-ec2-key (RSA 2048 / PEM, restrictive chmod, git-ignored)
#   - Never overwrite existing private keys or duplicate existing instances
#   - DocumentDB state is verified read-only; never modified, stopped, or exposed
#   - State saved to scripts/.ec2.env (chmod 600, git-ignored)
# ==============================================================================

set -euo pipefail

# --- Color formatting helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "  ${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
log_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }

# --- Argument Parsing ---
DRY_RUN=false
for arg in "$@"; do
    case "${arg}" in
        --dry-run)
            DRY_RUN=true
            ;;
        -h|--help)
            echo "Usage: $0 [--dry-run]"
            echo "  --dry-run    Inspect prerequisites and display execution plan without creating resources."
            exit 0
            ;;
        *)
            echo "Unknown option: ${arg}"
            echo "Usage: $0 [--dry-run]"
            exit 1
            ;;
    esac
done

echo "================================================================"
echo "    UnQue 2.0 - Ubuntu 24.04 LTS EC2 Provisioning               "
if [[ "${DRY_RUN}" == "true" ]]; then
    echo "       Region: ap-south-1 | Mode: DRY-RUN (Plan Only)           "
else
    echo "       Region: ap-south-1 | Mode: LIVE PROVISIONING             "
fi
echo "================================================================"

# Cost notice for EC2
echo -e "${YELLOW}================================================================${NC}"
echo -e "${YELLOW} [BILLING NOTICE] EC2 t3.micro instances incur standard AWS hourly${NC}"
echo -e "${YELLOW} compute, EBS volume storage, and public IPv4 address charges.${NC}"
echo -e "${YELLOW} (Free-tier eligible if your account is within its first 12 months).${NC}"
echo -e "${YELLOW} Remember to stop or terminate instances when not in use.${NC}"
echo -e "${YELLOW}================================================================${NC}\n"

# --- Step 1: Load Existing Network & DocumentDB State ---
RESOURCES_ENV="scripts/.aws-resources.env"
if [[ ! -f "${RESOURCES_ENV}" ]]; then
    if [[ -f ".aws-resources.env" ]]; then
        RESOURCES_ENV=".aws-resources.env"
    else
        log_fail "Network configuration file 'scripts/.aws-resources.env' not found!"
        log_info "Please run scripts/01-network.sh first to provision VPC, subnets, and security groups."
        exit 1
    fi
fi

# shellcheck source=/dev/null
source "${RESOURCES_ENV}"

# Load DocumentDB configuration if available
DOCDB_ENV="scripts/.docdb.env"
if [[ -f "${DOCDB_ENV}" ]]; then
    # shellcheck source=/dev/null
    source "${DOCDB_ENV}"
fi

AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT_TAG="unque-2.0"
INSTANCE_NAME="unque-ec2-backend"
INSTANCE_TYPE="t3.micro"
KEY_NAME="unque-ec2-key"
LOCAL_KEY_PATH="scripts/unque-ec2-key.pem"
STATE_FILE="scripts/.ec2.env"

# Ensure all expected variables are present
MISSING_VARS=()
[[ -z "${VPC_ID:-}" ]] && MISSING_VARS+=("VPC_ID")
[[ -z "${PUBLIC_SUBNET_ID:-}" ]] && MISSING_VARS+=("PUBLIC_SUBNET_ID")
[[ -z "${EC2_SG_ID:-}" ]] && MISSING_VARS+=("EC2_SG_ID")
[[ -z "${DOCDB_SG_ID:-}" ]] && MISSING_VARS+=("DOCDB_SG_ID")
[[ -z "${DOCDB_CLUSTER_ID:-}" ]] && MISSING_VARS+=("DOCDB_CLUSTER_ID")
[[ -z "${DOCDB_INSTANCE_ID:-}" ]] && MISSING_VARS+=("DOCDB_INSTANCE_ID")

if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
    log_fail "Missing required variables in configuration files: ${MISSING_VARS[*]}"
    log_info "Ensure scripts/01-network.sh and scripts/02-documentdb.sh have completed successfully."
    exit 1
fi

# Track newly created resources for safe error handling (Requirement 15)
NEWLY_CREATED_RESOURCES=()

cleanup_on_exit() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        echo -e "\n${RED}[ERROR] Script failed with exit code ${exit_code}.${NC}"
        if [[ ${#NEWLY_CREATED_RESOURCES[@]} -gt 0 ]]; then
            echo -e "${YELLOW}[WARNING] The following resources were initiated during this run before the error:${NC}"
            for cmd in "${NEWLY_CREATED_RESOURCES[@]}"; do
                echo -e "  - ${cmd}"
            done
            echo -e "${YELLOW}Pre-existing resources (VPC, Subnets, Security Groups, DocumentDB) were NOT modified or deleted.${NC}"
        fi
    fi
}
trap cleanup_on_exit EXIT

# --- Step 2: Validate Network & DocumentDB Prerequisites (Requirements 9, 10, 16) ---
echo -e "${CYAN}Step 1: Validating prerequisite network and DocumentDB infrastructure...${NC}"

# 1. Validate VPC
VALID_VPC=$(aws ec2 describe-vpcs \
    --region "${AWS_REGION}" \
    --vpc-ids "${VPC_ID}" \
    --query "Vpcs[0].VpcId" \
    --output text 2>/dev/null || true)
if [[ "${VALID_VPC}" != "${VPC_ID}" ]]; then
    log_fail "VPC '${VPC_ID}' does not exist in region '${AWS_REGION}'."
    exit 1
fi
log_pass "VPC verified: ${VPC_ID}"

# 2. Validate Public Subnet
read -r VALID_SUBNET SUBNET_AZ SUBNET_VPC SUBNET_MAP_PUB <<< "$(aws ec2 describe-subnets \
    --region "${AWS_REGION}" \
    --subnet-ids "${PUBLIC_SUBNET_ID}" \
    --query "Subnets[0].[SubnetId,AvailabilityZone,VpcId,MapPublicIpOnLaunch]" \
    --output text 2>/dev/null || true)"

if [[ "${VALID_SUBNET}" != "${PUBLIC_SUBNET_ID}" ]]; then
    log_fail "Public subnet '${PUBLIC_SUBNET_ID}' does not exist in ${AWS_REGION}."
    exit 1
fi
if [[ "${SUBNET_VPC}" != "${VPC_ID}" ]]; then
    log_fail "Public subnet belongs to VPC '${SUBNET_VPC}', but expected VPC is '${VPC_ID}'."
    exit 1
fi
log_pass "Public subnet verified: ${PUBLIC_SUBNET_ID} (AZ: ${SUBNET_AZ}, MapPublicIp: ${SUBNET_MAP_PUB})"

# 3. Validate EC2 Security Group
VALID_EC2_SG=$(aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --group-ids "${EC2_SG_ID}" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || true)
if [[ "${VALID_EC2_SG}" != "${EC2_SG_ID}" ]]; then
    log_fail "EC2 Security Group '${EC2_SG_ID}' does not exist in ${AWS_REGION}."
    exit 1
fi
log_pass "EC2 Security Group verified: ${EC2_SG_ID}"

# 4. Validate DocumentDB Cluster and Instance (Read-only, Requirement 16)
read -r DOCDB_REAL_STATUS DOCDB_REAL_ENDPOINT DOCDB_REAL_PORT <<< "$(aws docdb describe-db-clusters \
    --region "${AWS_REGION}" \
    --db-cluster-identifier "${DOCDB_CLUSTER_ID}" \
    --query "DBClusters[0].[Status,Endpoint,Port]" \
    --output text 2>/dev/null || true)"

if [[ "${DOCDB_REAL_STATUS}" != "available" ]]; then
    log_fail "DocumentDB cluster '${DOCDB_CLUSTER_ID}' status is '${DOCDB_REAL_STATUS}', expected 'available'."
    exit 1
fi

read -r INST_REAL_STATUS INST_CLASS INST_PUBLIC <<< "$(aws docdb describe-db-instances \
    --region "${AWS_REGION}" \
    --db-instance-identifier "${DOCDB_INSTANCE_ID}" \
    --query "DBInstances[0].[DBInstanceStatus,DBInstanceClass,PubliclyAccessible]" \
    --output text 2>/dev/null || true)"

if [[ "${INST_REAL_STATUS}" != "available" ]]; then
    log_fail "DocumentDB instance '${DOCDB_INSTANCE_ID}' status is '${INST_REAL_STATUS}', expected 'available'."
    exit 1
fi

# 5. Verify DocumentDB is NOT publicly exposed (Requirement 9)
if [[ "${INST_PUBLIC}" == "True" || "${INST_PUBLIC}" == "true" ]]; then
    log_fail "Security violation: DocumentDB instance '${DOCDB_INSTANCE_ID}' has PubliclyAccessible=true!"
    exit 1
fi

# Verify DocumentDB Security Group has zero 0.0.0.0/0 ingress
DOCDB_PUBLIC_INGRESS=$(aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --group-ids "${DOCDB_SG_ID}" \
    --filters "Name=ip-permission.cidr,Values=0.0.0.0/0" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || true)
if [[ -n "${DOCDB_PUBLIC_INGRESS}" && "${DOCDB_PUBLIC_INGRESS}" != "None" ]]; then
    log_fail "Security violation: DocumentDB security group '${DOCDB_SG_ID}' allows 0.0.0.0/0 ingress!"
    exit 1
fi
log_pass "DocumentDB verified: Cluster and Instance available, private to VPC (zero public access)."

# --- Step 3: Validate SSH Ingress & Detect Public IP Changes (Requirement 8) ---
echo -e "\n${CYAN}Step 2: Checking SSH rule against current public IP...${NC}"

CURRENT_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)
if [[ -z "${CURRENT_IP}" ]]; then
    CURRENT_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)
fi

AUTHORIZED_SSH_CIDRS=$(aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --group-ids "${EC2_SG_ID}" \
    --filters "Name=ip-permission.protocol,Values=tcp" \
              "Name=ip-permission.from-port,Values=22" \
              "Name=ip-permission.to-port,Values=22" \
    --query "SecurityGroups[0].IpPermissions[0].IpRanges[*].CidrIp" \
    --output text 2>/dev/null || true)

if [[ -n "${CURRENT_IP}" ]]; then
    if echo "${AUTHORIZED_SSH_CIDRS}" | grep -qw "${CURRENT_IP}/32"; then
        log_pass "Current public IP (${CURRENT_IP}/32) is authorized for SSH in security group ${EC2_SG_ID}."
    else
        log_warn "Current public IP is ${CURRENT_IP}, but authorized SSH rules are: [${AUTHORIZED_SSH_CIDRS:-none}]."
        echo -e "${YELLOW}  If your ISP assigned a new IP address, authorize it by running:${NC}"
        echo -e "  aws ec2 authorize-security-group-ingress --region ${AWS_REGION} --group-id ${EC2_SG_ID} --protocol tcp --port 22 --cidr ${CURRENT_IP}/32\n"
    fi
else
    log_warn "Could not auto-detect current public IP. Configured SSH rule: ${AUTHORIZED_SSH_CIDRS:-none}"
fi

# --- Step 4: Resolve Ubuntu Server 24.04 LTS AMI & Instance Offering (Requirements 1, 2) ---
echo -e "\n${CYAN}Step 3: Resolving Ubuntu 24.04 LTS AMI and instance class availability...${NC}"

# Query Canonical official Ubuntu 24.04 LTS (Noble) amd64 AMI
read -r AMI_ID AMI_NAME AMI_CREATION <<< "$(aws ec2 describe-images \
    --region "${AWS_REGION}" \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
              "Name=state,Values=available" \
    --query "reverse(sort_by(Images, &CreationDate))[0].[ImageId,Name,CreationDate]" \
    --output text 2>/dev/null || true)"

if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
    log_fail "Could not find official Canonical Ubuntu 24.04 LTS AMI in ${AWS_REGION}."
    exit 1
fi
log_pass "Resolved Ubuntu 24.04 LTS AMI: ${AMI_ID} (${AMI_NAME})"

# Verify t3.micro availability in subnet's AZ
OFFERED_TYPES=$(aws ec2 describe-instance-type-offerings \
    --region "${AWS_REGION}" \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=${INSTANCE_TYPE}" \
              "Name=location,Values=${SUBNET_AZ}" \
    --query "InstanceTypeOfferings[*].InstanceType" \
    --output text 2>/dev/null || true)

if ! echo "${OFFERED_TYPES}" | grep -qw "${INSTANCE_TYPE}"; then
    log_fail "Instance type '${INSTANCE_TYPE}' is NOT offered in AZ '${SUBNET_AZ}'."
    exit 1
fi
log_pass "Confirmed: '${INSTANCE_TYPE}' is offered in ${SUBNET_AZ}."

# --- Step 5: EC2 Key Pair Management (Requirements 6, 7) ---
echo -e "\n${CYAN}Step 4: Inspecting EC2 SSH Key Pair '${KEY_NAME}'...${NC}"

EXISTING_AWS_KEY=$(aws ec2 describe-key-pairs \
    --region "${AWS_REGION}" \
    --key-names "${KEY_NAME}" \
    --query "KeyPairs[0].KeyName" \
    --output text 2>/dev/null || true)
[[ "${EXISTING_AWS_KEY}" == "None" ]] && EXISTING_AWS_KEY=""

LOCAL_KEY_EXISTS=false
[[ -f "${LOCAL_KEY_PATH}" ]] && LOCAL_KEY_EXISTS=true

if [[ -n "${EXISTING_AWS_KEY}" && "${LOCAL_KEY_EXISTS}" == "true" ]]; then
    log_pass "Key pair '${KEY_NAME}' exists in AWS and locally at '${LOCAL_KEY_PATH}' (reusing)."
    chmod 400 "${LOCAL_KEY_PATH}" 2>/dev/null || true
elif [[ -z "${EXISTING_AWS_KEY}" && "${LOCAL_KEY_EXISTS}" == "true" ]]; then
    log_fail "Local key file '${LOCAL_KEY_PATH}' exists, but key pair '${KEY_NAME}' does not exist in AWS."
    log_info "To prevent overwriting an existing private key, rename or remove '${LOCAL_KEY_PATH}', or import it to AWS."
    exit 1
elif [[ -n "${EXISTING_AWS_KEY}" && "${LOCAL_KEY_EXISTS}" == "false" ]]; then
    log_fail "Key pair '${KEY_NAME}' exists in AWS, but local private key file '${LOCAL_KEY_PATH}' is missing!"
    log_info "AWS does not allow re-downloading existing private keys. If you lost the private key, delete the key pair in AWS:"
    log_info "  aws ec2 delete-key-pair --region ${AWS_REGION} --key-name ${KEY_NAME}"
    exit 1
else
    log_info "Key pair '${KEY_NAME}' does not exist. A new key pair will be created and saved to '${LOCAL_KEY_PATH}'."
fi

# --- Step 6: Check for Existing EC2 Instance (Requirement 11) ---
echo -e "\n${CYAN}Step 5: Checking for existing EC2 instance...${NC}"

EXISTING_INSTANCE_ID=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=tag:Project,Values=${PROJECT_TAG}" \
              "Name=instance-state-name,Values=running,stopped,pending" \
              "Name=vpc-id,Values=${VPC_ID}" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text 2>/dev/null || true)
[[ "${EXISTING_INSTANCE_ID}" == "None" ]] && EXISTING_INSTANCE_ID=""

EXISTING_INSTANCE_STATE=""
EXISTING_INSTANCE_IP=""
EXISTING_INSTANCE_DNS=""

if [[ -n "${EXISTING_INSTANCE_ID}" ]]; then
    read -r EXISTING_INSTANCE_STATE EXISTING_INSTANCE_TYPE EXISTING_SUBNET EXISTING_KEY EXISTING_INSTANCE_IP EXISTING_INSTANCE_DNS <<< "$(aws ec2 describe-instances \
        --region "${AWS_REGION}" \
        --instance-ids "${EXISTING_INSTANCE_ID}" \
        --query "Reservations[0].Instances[0].[State.Name,InstanceType,SubnetId,KeyName,PublicIpAddress,PublicDnsName]" \
        --output text)"

    log_info "Found existing instance '${EXISTING_INSTANCE_ID}' (State: ${EXISTING_INSTANCE_STATE}). Validating configuration..."

    if [[ "${EXISTING_SUBNET}" != "${PUBLIC_SUBNET_ID}" ]]; then
        log_fail "Existing instance is in subnet '${EXISTING_SUBNET}', expected public subnet '${PUBLIC_SUBNET_ID}'."
        exit 1
    fi
    if [[ "${EXISTING_INSTANCE_TYPE}" != "${INSTANCE_TYPE}" ]]; then
        log_fail "Existing instance type is '${EXISTING_INSTANCE_TYPE}', expected '${INSTANCE_TYPE}'."
        exit 1
    fi

    # Verify security group
    INST_SGS=$(aws ec2 describe-instances \
        --region "${AWS_REGION}" \
        --instance-ids "${EXISTING_INSTANCE_ID}" \
        --query "Reservations[0].Instances[0].SecurityGroups[*].GroupId" \
        --output text)
    if ! echo "${INST_SGS}" | grep -qw "${EC2_SG_ID}"; then
        log_fail "Existing instance does not have required Security Group '${EC2_SG_ID}' attached."
        exit 1
    fi

    log_pass "Existing instance '${EXISTING_INSTANCE_ID}' validated: Type=${EXISTING_INSTANCE_TYPE}, Subnet=${EXISTING_SUBNET}, State=${EXISTING_INSTANCE_STATE}."
else
    log_info "No existing instance with tag '${INSTANCE_NAME}' found. A new instance will be launched."
fi

# --- Step 7: Execution Plan Summary & Dry-Run Exit (Requirement 13) ---
echo -e "\n--- Execution Plan Summary ---"
echo "  Region                 : ${AWS_REGION}"
echo "  VPC ID                 : ${VPC_ID}"
echo "  Public Subnet ID       : ${PUBLIC_SUBNET_ID} (AZ: ${SUBNET_AZ})"
echo "  EC2 Security Group     : ${EC2_SG_ID} (SSH 22, API 5001)"
echo "  Operating System       : Ubuntu Server 24.04 LTS (x86_64)"
echo "  AMI ID                 : ${AMI_ID} (${AMI_NAME})"
echo "  Instance Type          : ${INSTANCE_TYPE} (1 vCPU, 1 GiB RAM)"
echo "  Associate Public IP    : true"
echo "  Key Pair Name          : ${KEY_NAME}"
echo "  Local Key Path         : ${LOCAL_KEY_PATH}"
echo "  Target DocumentDB      : ${DOCDB_REAL_ENDPOINT}:${DOCDB_REAL_PORT} (Private VPC)"
if [[ -n "${EXISTING_INSTANCE_ID}" ]]; then
    echo "  Action                 : REUSE existing EC2 instance (${EXISTING_INSTANCE_ID})"
else
    echo "  Action                 : LAUNCH new EC2 instance (${INSTANCE_NAME})"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "\n${GREEN}[PASS] Dry-run complete. All prerequisite checks passed.${NC}"
    echo -e "${GREEN}No AWS resources were created, modified, or deleted.${NC}"
    exit 0
fi

# --- Step 8: User Confirmation (Requirement 14) ---
echo -e "\n${YELLOW}================================================================${NC}"
echo -e "${YELLOW}Confirmation Required:${NC}"
echo -e "You are about to launch an EC2 instance (${INSTANCE_TYPE}, Ubuntu 24.04 LTS) in ${AWS_REGION}."
echo -e "This will incur charges on your AWS account while running."
echo -e "${YELLOW}================================================================${NC}"
read -r -p "Do you want to proceed with provisioning? [y/N]: " USER_CONFIRM
if [[ ! "${USER_CONFIRM}" =~ ^[Yy]$ ]]; then
    log_info "Provisioning aborted by user. Exiting."
    exit 0
fi

# --- Step 9: Create Key Pair if Needed (Requirements 6, 7) ---
if [[ -z "${EXISTING_AWS_KEY}" ]]; then
    echo -e "\n${CYAN}Step 6: Creating EC2 Key Pair '${KEY_NAME}'...${NC}"
    
    # Ensure directory exists and restrict permissions
    mkdir -p "$(dirname "${LOCAL_KEY_PATH}")"
    
    aws ec2 create-key-pair \
        --region "${AWS_REGION}" \
        --key-name "${KEY_NAME}" \
        --key-type rsa \
        --key-format pem \
        --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=${KEY_NAME}},{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "KeyMaterial" \
        --output text > "${LOCAL_KEY_PATH}"

    chmod 400 "${LOCAL_KEY_PATH}" 2>/dev/null || true
    NEWLY_CREATED_RESOURCES+=("aws ec2 delete-key-pair --region ${AWS_REGION} --key-name ${KEY_NAME} && rm -f ${LOCAL_KEY_PATH}")
    log_pass "Created key pair '${KEY_NAME}' and saved private key to '${LOCAL_KEY_PATH}' (permissions: 400)."
fi

# --- Step 10: Launch EC2 Instance (Requirements 1, 2, 3, 4, 5, 11) ---
INSTANCE_ID=""
INSTANCE_PUBLIC_IP=""
INSTANCE_PUBLIC_DNS=""

if [[ -z "${EXISTING_INSTANCE_ID}" ]]; then
    echo -e "\n${CYAN}Step 7: Launching Ubuntu 24.04 LTS EC2 Instance...${NC}"

    INSTANCE_ID=$(aws ec2 run-instances \
        --region "${AWS_REGION}" \
        --image-id "${AMI_ID}" \
        --instance-type "${INSTANCE_TYPE}" \
        --key-name "${KEY_NAME}" \
        --subnet-id "${PUBLIC_SUBNET_ID}" \
        --security-group-ids "${EC2_SG_ID}" \
        --associate-public-ip-address \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${PROJECT_TAG}}]" \
                             "ResourceType=volume,Tags=[{Key=Name,Value=unque-ec2-root-vol},{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "Instances[0].InstanceId" \
        --output text)

    NEWLY_CREATED_RESOURCES+=("aws ec2 terminate-instances --region ${AWS_REGION} --instance-ids ${INSTANCE_ID}")
    log_pass "Launched EC2 instance: ${INSTANCE_ID}"

    log_info "Waiting for instance '${INSTANCE_ID}' to enter 'running' state..."
    aws ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "${INSTANCE_ID}"
    log_pass "Instance '${INSTANCE_ID}' is now running!"

    # Query assigned Public IP and Public DNS
    read -r INSTANCE_PUBLIC_IP INSTANCE_PUBLIC_DNS <<< "$(aws ec2 describe-instances \
        --region "${AWS_REGION}" \
        --instance-ids "${INSTANCE_ID}" \
        --query "Reservations[0].Instances[0].[PublicIpAddress,PublicDnsName]" \
        --output text)"
else
    INSTANCE_ID="${EXISTING_INSTANCE_ID}"
    INSTANCE_PUBLIC_IP="${EXISTING_INSTANCE_IP}"
    INSTANCE_PUBLIC_DNS="${EXISTING_INSTANCE_DNS}"

    if [[ "${EXISTING_INSTANCE_STATE}" == "stopped" ]]; then
        log_info "Instance '${INSTANCE_ID}' is currently stopped. Starting instance..."
        aws ec2 start-instances --region "${AWS_REGION}" --instance-ids "${INSTANCE_ID}" >/dev/null
        aws ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "${INSTANCE_ID}"
        read -r INSTANCE_PUBLIC_IP INSTANCE_PUBLIC_DNS <<< "$(aws ec2 describe-instances \
            --region "${AWS_REGION}" \
            --instance-ids "${INSTANCE_ID}" \
            --query "Reservations[0].Instances[0].[PublicIpAddress,PublicDnsName]" \
            --output text)"
        log_pass "Instance '${INSTANCE_ID}' is now running with Public IP: ${INSTANCE_PUBLIC_IP}"
    else
        log_pass "Reusing existing running instance: ${INSTANCE_ID}"
    fi
fi

# --- Step 11: Save State File (Requirement 12) ---
echo -e "\n${CYAN}Step 8: Saving EC2 state to ${STATE_FILE}...${NC}"

touch "${STATE_FILE}"
chmod 600 "${STATE_FILE}" 2>/dev/null || true

cat <<EOF > "${STATE_FILE}"
# Auto-generated by scripts/03-ec2.sh on $(date -u +"%Y-%m-%d %H:%M:%SZ")
AWS_REGION="${AWS_REGION}"
VPC_ID="${VPC_ID}"
PUBLIC_SUBNET_ID="${PUBLIC_SUBNET_ID}"
EC2_SG_ID="${EC2_SG_ID}"
EC2_INSTANCE_ID="${INSTANCE_ID}"
EC2_INSTANCE_NAME="${INSTANCE_NAME}"
EC2_INSTANCE_TYPE="${INSTANCE_TYPE}"
EC2_AMI_ID="${AMI_ID}"
EC2_AMI_NAME="${AMI_NAME}"
EC2_KEY_NAME="${KEY_NAME}"
EC2_KEY_PATH="${LOCAL_KEY_PATH}"
EC2_PUBLIC_IP="${INSTANCE_PUBLIC_IP}"
EC2_PUBLIC_DNS="${INSTANCE_PUBLIC_DNS}"
EC2_SSH_USER="ubuntu"
EOF

chmod 600 "${STATE_FILE}" 2>/dev/null || true
log_pass "Saved EC2 state to ${STATE_FILE} (permissions: 0600)."

# Also update scripts/.aws-resources.env
if [[ -f "${RESOURCES_ENV}" ]]; then
    sed -i '/^EC2_INSTANCE_ID=/d' "${RESOURCES_ENV}" 2>/dev/null || true
    sed -i '/^EC2_PUBLIC_IP=/d' "${RESOURCES_ENV}" 2>/dev/null || true
    sed -i '/^EC2_PUBLIC_DNS=/d' "${RESOURCES_ENV}" 2>/dev/null || true
    sed -i '/^EC2_KEY_NAME=/d' "${RESOURCES_ENV}" 2>/dev/null || true
    sed -i '/^EC2_KEY_PATH=/d' "${RESOURCES_ENV}" 2>/dev/null || true
    cat <<EOF >> "${RESOURCES_ENV}"
EC2_INSTANCE_ID="${INSTANCE_ID}"
EC2_PUBLIC_IP="${INSTANCE_PUBLIC_IP}"
EC2_PUBLIC_DNS="${INSTANCE_PUBLIC_DNS}"
EC2_KEY_NAME="${KEY_NAME}"
EC2_KEY_PATH="${LOCAL_KEY_PATH}"
EOF
    log_pass "Updated ${RESOURCES_ENV} with EC2 instance details."
fi

# --- Step 12: Final Summary Output ---
echo -e "\n================================================================"
echo -e "          EC2 Provisioning Completed Successfully               "
echo -e "================================================================"
echo -e "  AWS Region         : ${AWS_REGION}"
echo -e "  Instance ID        : ${INSTANCE_ID}"
echo -e "  Instance Type      : ${INSTANCE_TYPE}"
echo -e "  AMI ID             : ${AMI_ID} (${AMI_NAME})"
echo -e "  Public IPv4 Address: ${INSTANCE_PUBLIC_IP}"
echo -e "  Public DNS Name    : ${INSTANCE_PUBLIC_DNS}"
echo -e "  SSH Key Pair Name  : ${KEY_NAME}"
echo -e "  Local Key File     : ${LOCAL_KEY_PATH} (chmod 400)"
echo -e "  Security Group     : ${EC2_SG_ID} (SSH 22, API 5001)"
echo -e "  State File         : ${STATE_FILE} (chmod 600, excluded from git)"
echo -e "================================================================"
echo -e "  SSH Connection Command:"
echo -e "  ssh -i \"${LOCAL_KEY_PATH}\" ubuntu@${INSTANCE_PUBLIC_IP}"
echo -e "================================================================"
echo -e "  [NEXT STEP] Application deployment and PM2 configuration will"
echo -e "  be performed in the next phase (scripts/04-deploy-app.sh)."
echo -e "================================================================"
echo -e "${YELLOW}  [COST REMINDER] To stop charges when not testing:${NC}"
echo -e "${YELLOW}  aws ec2 stop-instances --instance-ids ${INSTANCE_ID}${NC}"
echo -e "================================================================\n"
