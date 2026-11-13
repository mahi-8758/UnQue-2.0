#!/usr/bin/env bash

# ==============================================================================
# Script: scripts/01-network.sh
# Purpose: Provision dedicated AWS networking infrastructure for UnQue 2.0 in ap-south-1.
#
# Resources Provisioned:
#   1. Dedicated VPC: 10.20.0.0/16 (tagged: unque-vpc)
#   2. Public Subnet: 10.20.1.0/24 (AZ1, public IP auto-assigned, for EC2)
#   3. Private Subnet 1: 10.20.2.0/24 (AZ1, no public IP, for DocumentDB)
#   4. Private Subnet 2: 10.20.3.0/24 (AZ2, no public IP, for DocumentDB)
#   5. Internet Gateway (IGW) attached to unque-vpc
#   6. Public Route Table with 0.0.0.0/0 route to IGW (associated with public subnet only)
#   7. EC2 Security Group:
#      - SSH (TCP 22) restricted strictly to user-specified public IPv4 /32 (never 0.0.0.0/0)
#      - App (TCP 5001) restricted to trusted IPv4 CIDR
#   8. DocumentDB Security Group:
#      - MongoDB port (TCP 27017) restricted strictly to EC2 Security Group (no public access)
#   9. DocumentDB Subnet Group spanning the two private subnets across 2 AZs
#  10. Local state saved to scripts/.aws-resources.env
#
# Features:
#   - Idempotent: checks for existing tagged resources before creating to avoid duplicates.
#   - Dry-Run Mode (--dry-run): inspects and plans without making mutations.
#   - Safety Confirmation: prompts user before provisioning billable/persistent resources.
#   - Failure Tracking: records newly created resources and prints cleanup commands on failure.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Environment & Parameter Defaults
# ------------------------------------------------------------------------------
AWS_REGION="ap-south-1"
export AWS_REGION="${AWS_REGION}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

PROJECT_TAG="unque-2.0"
VPC_CIDR="10.20.0.0/16"
PUBLIC_SUBNET_CIDR="10.20.1.0/24"
PRIVATE_SUBNET_1_CIDR="10.20.2.0/24"
PRIVATE_SUBNET_2_CIDR="10.20.3.0/24"

STATE_FILE="scripts/.aws-resources.env"

# Flags
DRY_RUN=false
AUTO_CONFIRM=false
SSH_IP_INPUT=""
APP_CIDR_INPUT=""

# Colors for terminal output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m"

# Array to track resources created during this specific execution for rollback guidance
NEWLY_CREATED_RESOURCES=()

# Helper output functions
log_info()  { echo -e "  [${BLUE}INFO${NC}] $1"; }
log_pass()  { echo -e "  [${GREEN}${BOLD}PASS${NC}] $1"; }
log_plan()  { echo -e "  [${CYAN}${BOLD}PLAN${NC}] $1"; }
log_warn()  { echo -e "  [${YELLOW}${BOLD}WARN${NC}] $1"; }
log_fail()  { echo -e "  [${RED}${BOLD}FAIL${NC}] $1"; }

# ------------------------------------------------------------------------------
# 2. Parse CLI Arguments
# ------------------------------------------------------------------------------
print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  --dry-run               Plan and validate without creating any AWS resources.
  --ssh-ip <IP_or_CIDR>   Your public IPv4 address for SSH (e.g. 203.0.113.10 or 203.0.113.10/32).
                          MUST NOT be 0.0.0.0/0.
  --app-cidr <CIDR>       Trusted IPv4 CIDR for API port 5001 (e.g. 203.0.113.10/32 or 0.0.0.0/0).
                          Defaults to the SSH IP /32 if not specified.
  -y, --yes               Skip confirmation prompt (auto-approve).
  -h, --help              Show this help message.

Environment Variables:
  SSH_IP                  Alternative to --ssh-ip
  APP_CIDR                Alternative to --app-cidr
  DRY_RUN=true            Alternative to --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --ssh-ip)
            SSH_IP_INPUT="$2"
            shift 2
            ;;
        --app-cidr)
            APP_CIDR_INPUT="$2"
            shift 2
            ;;
        -y|--yes)
            AUTO_CONFIRM=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Check environment variable fallbacks
SSH_IP_INPUT="${SSH_IP_INPUT:-${SSH_IP:-}}"
APP_CIDR_INPUT="${APP_CIDR_INPUT:-${APP_CIDR:-}}"
if [[ "${DRY_RUN}" == "false" && "${DRY_RUN_ENV:-}" == "true" ]]; then
    DRY_RUN=true
fi

# ------------------------------------------------------------------------------
# 3. Clean Error Handler (Trap on Failure)
# ------------------------------------------------------------------------------
cleanup_on_failure() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 && "${DRY_RUN}" == "false" ]]; then
        echo ""
        echo -e "${RED}${BOLD}================================================================${NC}"
        echo -e "${RED}${BOLD}  DEPLOYMENT FAILED (Exit Code: ${exit_code})                    ${NC}"
        echo -e "${RED}${BOLD}================================================================${NC}"
        if [[ ${#NEWLY_CREATED_RESOURCES[@]} -gt 0 ]]; then
            echo -e "The following resources were ${YELLOW}newly created${NC} during this run before failure:"
            for res in "${NEWLY_CREATED_RESOURCES[@]}"; do
                echo -e "  - ${res}"
            done
            echo ""
            echo -e "${BOLD}To clean up newly created resources manually, run (in reverse order):${NC}"
            for (( i=${#NEWLY_CREATED_RESOURCES[@]}-1; i>=0; i-- )); do
                echo "  ${NEWLY_CREATED_RESOURCES[i]}"
            done
            echo ""
            log_warn "Pre-existing resources were NOT modified or tracked for deletion."
        else
            log_info "No new AWS resources were created prior to this error."
        fi
        echo -e "${RED}${BOLD}================================================================${NC}"
    fi
}
trap cleanup_on_failure EXIT

# ------------------------------------------------------------------------------
# 4. Banner & Preflight Validation
# ------------------------------------------------------------------------------
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}      UnQue 2.0 - VPC & Network Infrastructure Provisioning     ${NC}"
echo -e "${BLUE}${BOLD}      Region: ${AWS_REGION} | Mode: $([[ "${DRY_RUN}" == "true" ]] && echo "DRY-RUN (Plan Only)" || echo "LIVE PROVISIONING") ${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo ""

# Verify AWS CLI installed
if ! command -v aws >/dev/null 2>&1; then
    log_fail "AWS CLI is required but not installed. Run scripts/00-preflight.sh first."
    exit 1
fi

# Verify AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_fail "AWS credentials invalid or not configured. Run scripts/00-preflight.sh first."
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. Determine & Validate SSH and App CIDRs
# ------------------------------------------------------------------------------
echo -e "${BOLD}Validating IP configuration for Security Groups...${NC}"

# If SSH IP not provided, attempt to auto-detect current public IP as suggestion
if [[ -z "${SSH_IP_INPUT}" ]]; then
    DETECTED_IP=$(curl -s --max-time 4 https://checkip.amazonaws.com 2>/dev/null || echo "")
    if [[ -n "${DETECTED_IP}" ]]; then
        log_info "Auto-detected current public IP: ${DETECTED_IP}"
        SSH_IP_INPUT="${DETECTED_IP}"
    else
        log_fail "SSH IP was not provided and could not be auto-detected."
        echo "       Pass --ssh-ip <YOUR_PUBLIC_IP> or set SSH_IP=<YOUR_PUBLIC_IP>."
        exit 1
    fi
fi

# Format SSH IP to /32
if [[ "${SSH_IP_INPUT}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SSH_CIDR="${SSH_IP_INPUT}/32"
elif [[ "${SSH_IP_INPUT}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32$ ]]; then
    SSH_CIDR="${SSH_IP_INPUT}"
else
    log_fail "Invalid SSH IP format: '${SSH_IP_INPUT}'. Must be a single IPv4 address (e.g. 203.0.113.10 or 203.0.113.10/32)."
    exit 1
fi

# Enforce Security Requirement 8: Never expose SSH to 0.0.0.0/0
if [[ "${SSH_CIDR}" == "0.0.0.0/0" || "${SSH_CIDR}" == "0.0.0.0/32" ]]; then
    log_fail "SECURITY VIOLATION: SSH (port 22) cannot be open to 0.0.0.0/0."
    exit 1
fi
log_pass "SSH Access restricted to: ${SSH_CIDR}"

# Configure APP_CIDR (port 5001)
if [[ -z "${APP_CIDR_INPUT}" ]]; then
    APP_CIDR="${SSH_CIDR}"
    log_info "App CIDR not provided; defaulting to SSH IP: ${APP_CIDR}"
else
    APP_CIDR="${APP_CIDR_INPUT}"
    if [[ "${APP_CIDR}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        APP_CIDR="${APP_CIDR}/32"
    fi
    log_pass "App Access (port 5001) allowed from: ${APP_CIDR}"
fi
echo ""

# ------------------------------------------------------------------------------
# 6. Availability Zone Resolution
# ------------------------------------------------------------------------------
echo -e "${BOLD}Resolving Availability Zones in ${AWS_REGION}...${NC}"
AVAILABLE_AZS=($(aws ec2 describe-availability-zones \
    --region "${AWS_REGION}" \
    --filters "Name=state,Values=available" \
    --query "AvailabilityZones[].ZoneName" \
    --output text))

if [[ ${#AVAILABLE_AZS[@]} -lt 2 ]]; then
    log_fail "DocumentDB requires at least 2 Availability Zones. Found only: ${#AVAILABLE_AZS[@]}."
    exit 1
fi

AZ1="${AVAILABLE_AZS[0]}"
AZ2="${AVAILABLE_AZS[1]}"
log_pass "Selected Availability Zones: AZ1=${AZ1}, AZ2=${AZ2}"
echo ""

# ------------------------------------------------------------------------------
# 7. Pre-Scan Existing Resources (Idempotency Checks)
# ------------------------------------------------------------------------------
echo -e "${BOLD}Scanning for existing network resources with Project tag '${PROJECT_TAG}'...${NC}"

# Find VPC
EXISTING_VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=unque-vpc" "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)
[[ "${EXISTING_VPC_ID}" == "None" ]] && EXISTING_VPC_ID=""

# If VPC found by tag, validate its CIDR block
if [[ -n "${EXISTING_VPC_ID}" ]]; then
    VPC_ACTUAL_CIDR=$(aws ec2 describe-vpcs --vpc-ids "${EXISTING_VPC_ID}" --query "Vpcs[0].CidrBlock" --output text)
    if [[ "${VPC_ACTUAL_CIDR}" != "${VPC_CIDR}" ]]; then
        log_fail "Existing VPC ${EXISTING_VPC_ID} has CIDR ${VPC_ACTUAL_CIDR}, expected ${VPC_CIDR}."
        exit 1
    fi
    log_info "Found existing VPC: ${EXISTING_VPC_ID} (${VPC_ACTUAL_CIDR})"
else
    log_info "No existing VPC found. Will create a new VPC (${VPC_CIDR})."
fi

# Scan subnets if VPC exists
EXISTING_PUB_SUBNET=""
EXISTING_PRIV_SUBNET_1=""
EXISTING_PRIV_SUBNET_2=""
EXISTING_IGW=""
EXISTING_PUB_RT=""
EXISTING_EC2_SG=""
EXISTING_DOCDB_SG=""
EXISTING_DOCDB_SUBNET_GROUP=""

if [[ -n "${EXISTING_VPC_ID}" ]]; then
    EXISTING_PUB_SUBNET=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${EXISTING_VPC_ID}" "Name=cidr-block,Values=${PUBLIC_SUBNET_CIDR}" \
        --query "Subnets[0].SubnetId" --output text 2>/dev/null || true)
    [[ "${EXISTING_PUB_SUBNET}" == "None" ]] && EXISTING_PUB_SUBNET=""

    EXISTING_PRIV_SUBNET_1=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${EXISTING_VPC_ID}" "Name=cidr-block,Values=${PRIVATE_SUBNET_1_CIDR}" \
        --query "Subnets[0].SubnetId" --output text 2>/dev/null || true)
    [[ "${EXISTING_PRIV_SUBNET_1}" == "None" ]] && EXISTING_PRIV_SUBNET_1=""

    EXISTING_PRIV_SUBNET_2=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${EXISTING_VPC_ID}" "Name=cidr-block,Values=${PRIVATE_SUBNET_2_CIDR}" \
        --query "Subnets[0].SubnetId" --output text 2>/dev/null || true)
    [[ "${EXISTING_PRIV_SUBNET_2}" == "None" ]] && EXISTING_PRIV_SUBNET_2=""

    EXISTING_IGW=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=${EXISTING_VPC_ID}" \
        --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null || true)
    [[ "${EXISTING_IGW}" == "None" ]] && EXISTING_IGW=""

    EXISTING_PUB_RT=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=${EXISTING_VPC_ID}" "Name=tag:Name,Values=unque-public-rt" \
        --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || true)
    [[ "${EXISTING_PUB_RT}" == "None" ]] && EXISTING_PUB_RT=""

    EXISTING_EC2_SG=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${EXISTING_VPC_ID}" "Name=group-name,Values=unque-ec2-sg" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
    [[ "${EXISTING_EC2_SG}" == "None" ]] && EXISTING_EC2_SG=""

    EXISTING_DOCDB_SG=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${EXISTING_VPC_ID}" "Name=group-name,Values=unque-docdb-sg" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
    [[ "${EXISTING_DOCDB_SG}" == "None" ]] && EXISTING_DOCDB_SG=""
fi

EXISTING_DOCDB_SUBNET_GROUP=$(aws docdb describe-db-subnet-groups \
    --db-subnet-group-name unque-docdb-subnet-group \
    --query "DBSubnetGroups[0].DBSubnetGroupName" --output text 2>/dev/null || true)
[[ "${EXISTING_DOCDB_SUBNET_GROUP}" == "None" ]] && EXISTING_DOCDB_SUBNET_GROUP=""

# ------------------------------------------------------------------------------
# 8. Dry-Run / Planning Output
# ------------------------------------------------------------------------------
echo ""
echo -e "${CYAN}${BOLD}--- Execution Plan Summary ---${NC}"
echo -e "  Region                 : ${AWS_REGION}"
echo -e "  Target VPC CIDR        : ${VPC_CIDR}"
echo -e "  Target Public Subnet   : ${PUBLIC_SUBNET_CIDR} in ${AZ1} (MapPublicIP=true)"
echo -e "  Target Private Subnet 1: ${PRIVATE_SUBNET_1_CIDR} in ${AZ1} (MapPublicIP=false, No IGW Route)"
echo -e "  Target Private Subnet 2: ${PRIVATE_SUBNET_2_CIDR} in ${AZ2} (MapPublicIP=false, No IGW Route)"
echo -e "  Target EC2 SG          : Inbound 22 from ${SSH_CIDR}, 5001 from ${APP_CIDR}"
echo -e "  Target DocDB SG        : Inbound 27017 from EC2 SG only (Zero public access)"
echo -e "  Target DocDB Subnet Grp: unque-docdb-subnet-group (spanning ${AZ1} & ${AZ2})"
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "${CYAN}${BOLD}DRY-RUN ANALYSIS:${NC}"
    [[ -n "${EXISTING_VPC_ID}" ]]              && log_plan "VPC: Reuse ${EXISTING_VPC_ID}" || log_plan "VPC: CREATE new VPC (${VPC_CIDR})"
    [[ -n "${EXISTING_PUB_SUBNET}" ]]          && log_plan "Public Subnet: Reuse ${EXISTING_PUB_SUBNET}" || log_plan "Public Subnet: CREATE new subnet (${PUBLIC_SUBNET_CIDR})"
    [[ -n "${EXISTING_PRIV_SUBNET_1}" ]]       && log_plan "Private Subnet 1: Reuse ${EXISTING_PRIV_SUBNET_1}" || log_plan "Private Subnet 1: CREATE new subnet (${PRIVATE_SUBNET_1_CIDR})"
    [[ -n "${EXISTING_PRIV_SUBNET_2}" ]]       && log_plan "Private Subnet 2: Reuse ${EXISTING_PRIV_SUBNET_2}" || log_plan "Private Subnet 2: CREATE new subnet (${PRIVATE_SUBNET_2_CIDR})"
    [[ -n "${EXISTING_IGW}" ]]                 && log_plan "Internet Gateway: Reuse ${EXISTING_IGW}" || log_plan "Internet Gateway: CREATE and attach to VPC"
    [[ -n "${EXISTING_PUB_RT}" ]]              && log_plan "Public Route Table: Reuse ${EXISTING_PUB_RT}" || log_plan "Public Route Table: CREATE with 0.0.0.0/0 -> IGW"
    [[ -n "${EXISTING_EC2_SG}" ]]              && log_plan "EC2 SG: Reuse ${EXISTING_EC2_SG}" || log_plan "EC2 SG: CREATE (22 from ${SSH_CIDR}, 5001 from ${APP_CIDR})"
    [[ -n "${EXISTING_DOCDB_SG}" ]]            && log_plan "DocDB SG: Reuse ${EXISTING_DOCDB_SG}" || log_plan "DocDB SG: CREATE (27017 from EC2 SG only)"
    [[ -n "${EXISTING_DOCDB_SUBNET_GROUP}" ]]  && log_plan "DocDB Subnet Group: Reuse ${EXISTING_DOCDB_SUBNET_GROUP}" || log_plan "DocDB Subnet Group: CREATE"
    echo ""
    log_pass "Dry-run complete. No AWS resources were created or modified."
    exit 0
fi

# ------------------------------------------------------------------------------
# 9. Confirmation Prompt (Unless -y / --yes passed)
# ------------------------------------------------------------------------------
if [[ "${AUTO_CONFIRM}" == "false" ]]; then
    echo -e "${YELLOW}${BOLD}CONFIRMATION REQUIRED:${NC}"
    echo "You are about to provision persistent AWS network infrastructure in region ${AWS_REGION}."
    read -r -p "Do you want to proceed? [y/N]: " CONFIRM_RESP
    if [[ ! "${CONFIRM_RESP}" =~ ^[Yy]$ ]]; then
        echo "Aborted by user. No resources were modified."
        exit 0
    fi
    echo ""
fi

# ------------------------------------------------------------------------------
# 10. Live Provisioning
# ------------------------------------------------------------------------------

# --- Step A: VPC ---
if [[ -n "${EXISTING_VPC_ID}" ]]; then
    VPC_ID="${EXISTING_VPC_ID}"
    log_info "Reusing existing VPC: ${VPC_ID}"
else
    log_info "Creating VPC with CIDR ${VPC_CIDR}..."
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block "${VPC_CIDR}" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=unque-vpc},{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "Vpc.VpcId" --output text)
    NEWLY_CREATED_RESOURCES+=("aws ec2 delete-vpc --vpc-id ${VPC_ID}")
    log_pass "Created VPC: ${VPC_ID}"
fi

# Enable DNS support and hostnames on VPC (required for DocumentDB cluster endpoint resolution)
aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-support '{"Value":true}' >/dev/null
aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-hostnames '{"Value":true}' >/dev/null
log_pass "Enabled DNS support and hostnames on VPC."

# --- Step B: Subnets ---
# Public Subnet (AZ1)
if [[ -n "${EXISTING_PUB_SUBNET}" ]]; then
    PUBLIC_SUBNET_ID="${EXISTING_PUB_SUBNET}"
    log_info "Reusing existing Public Subnet: ${PUBLIC_SUBNET_ID}"
else
    log_info "Creating Public Subnet (${PUBLIC_SUBNET_CIDR}) in ${AZ1}..."
    PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
        --vpc-id "${VPC_ID}" \
        --cidr-block "${PUBLIC_SUBNET_CIDR}" \
        --availability-zone "${AZ1}" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=unque-public-subnet-1},{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "Subnet.SubnetId" --output text)
    NEWLY_CREATED_RESOURCES+=("aws ec2 delete-subnet --subnet-id ${PUBLIC_SUBNET_ID}")
    log_pass "Created Public Subnet: ${PUBLIC_SUBNET_ID}"
fi
# Enable auto-assign public IPv4 on public subnet
aws ec2 modify-subnet-attribute --subnet-id "${PUBLIC_SUBNET_ID}" --map-public-ip-on-launch >/dev/null
log_pass "Enabled public IPv4 auto-assignment on Public Subnet."

# Private Subnet 1 (AZ1)
if [[ -n "${EXISTING_PRIV_SUBNET_1}" ]]; then
    PRIVATE_SUBNET_1_ID="${EXISTING_PRIV_SUBNET_1}"
    log_info "Reusing existing Private Subnet 1: ${PRIVATE_SUBNET_1_ID}"
else
    log_info "Creating Private Subnet 1 (${PRIVATE_SUBNET_1_CIDR}) in ${AZ1}..."
    PRIVATE_SUBNET_1_ID=$(aws ec2 create-subnet \
        --vpc-id "${VPC_ID}" \
        --cidr-block "${PRIVATE_SUBNET_1_CIDR}" \
        --availability-zone "${AZ1}" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=unque-private-subnet-1},{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "Subnet.SubnetId" --output text)
    NEWLY_CREATED_RESOURCES+=("aws ec2 delete-subnet --subnet-id ${PRIVATE_SUBNET_1_ID}")
    log_pass "Created Private Subnet 1: ${PRIVATE_SUBNET_1_ID}"
fi

# Private Subnet 2 (AZ2)
if [[ -n "${EXISTING_PRIV_SUBNET_2}" ]]; then
    PRIVATE_SUBNET_2_ID="${EXISTING_PRIV_SUBNET_2}"
    log_info "Reusing existing Private Subnet 2: ${PRIVATE_SUBNET_2_ID}"
else
    log_info "Creating Private Subnet 2 (${PRIVATE_SUBNET_2_CIDR}) in ${AZ2}..."
    PRIVATE_SUBNET_2_ID=$(aws ec2 create-subnet \
        --vpc-id "${VPC_ID}" \
        --cidr-block "${PRIVATE_SUBNET_2_CIDR}" \
        --availability-zone "${AZ2}" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=unque-private-subnet-2},{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "Subnet.SubnetId" --output text)
    NEWLY_CREATED_RESOURCES+=("aws ec2 delete-subnet --subnet-id ${PRIVATE_SUBNET_2_ID}")
    log_pass "Created Private Subnet 2: ${PRIVATE_SUBNET_2_ID}"
fi

# --- Step C: Internet Gateway (IGW) ---
if [[ -n "${EXISTING_IGW}" ]]; then
    IGW_ID="${EXISTING_IGW}"
    log_info "Reusing existing Internet Gateway: ${IGW_ID}"
else
    log_info "Creating Internet Gateway..."
    IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=unque-igw},{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "InternetGateway.InternetGatewayId" --output text)
    NEWLY_CREATED_RESOURCES+=("aws ec2 detach-internet-gateway --internet-gateway-id ${IGW_ID} --vpc-id ${VPC_ID}")
    NEWLY_CREATED_RESOURCES+=("aws ec2 delete-internet-gateway --internet-gateway-id ${IGW_ID}")
    log_pass "Created Internet Gateway: ${IGW_ID}"

    log_info "Attaching Internet Gateway ${IGW_ID} to VPC ${VPC_ID}..."
    aws ec2 attach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"
    log_pass "Attached Internet Gateway to VPC."
fi

# --- Step D: Public Route Table ---
if [[ -n "${EXISTING_PUB_RT}" ]]; then
    PUBLIC_RT_ID="${EXISTING_PUB_RT}"
    log_info "Reusing existing Public Route Table: ${PUBLIC_RT_ID}"
else
    log_info "Creating Public Route Table..."
    PUBLIC_RT_ID=$(aws ec2 create-route-table \
        --vpc-id "${VPC_ID}" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=unque-public-rt},{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "RouteTable.RouteTableId" --output text)
    NEWLY_CREATED_RESOURCES+=("aws ec2 delete-route-table --route-table-id ${PUBLIC_RT_ID}")
    log_pass "Created Route Table: ${PUBLIC_RT_ID}"
fi

# Ensure 0.0.0.0/0 route exists targeting the IGW
HAS_DEFAULT_ROUTE=$(aws ec2 describe-route-tables \
    --route-table-id "${PUBLIC_RT_ID}" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" \
    --output text 2>/dev/null || true)

if [[ -z "${HAS_DEFAULT_ROUTE}" || "${HAS_DEFAULT_ROUTE}" == "None" ]]; then
    log_info "Adding default route 0.0.0.0/0 -> ${IGW_ID}..."
    aws ec2 create-route \
        --route-table-id "${PUBLIC_RT_ID}" \
        --destination-cidr-block "0.0.0.0/0" \
        --gateway-id "${IGW_ID}" >/dev/null
    log_pass "Added default route to Internet Gateway."
else
    log_info "Default route to IGW already exists in route table."
fi

# Associate Public Route Table with Public Subnet only
IS_ASSOCIATED=$(aws ec2 describe-route-tables \
    --route-table-id "${PUBLIC_RT_ID}" \
    --query "RouteTables[0].Associations[?SubnetId=='${PUBLIC_SUBNET_ID}'].RouteTableAssociationId" \
    --output text 2>/dev/null || true)

if [[ -z "${IS_ASSOCIATED}" || "${IS_ASSOCIATED}" == "None" ]]; then
    log_info "Associating Public Route Table with Public Subnet ${PUBLIC_SUBNET_ID}..."
    ASSOC_ID=$(aws ec2 associate-route-table \
        --route-table-id "${PUBLIC_RT_ID}" \
        --subnet-id "${PUBLIC_SUBNET_ID}" \
        --query "AssociationId" --output text)
    log_pass "Associated Public Route Table with Public Subnet (Association ID: ${ASSOC_ID})."
else
    log_info "Public Route Table already associated with Public Subnet."
fi

# --- Step E: Security Groups ---

# 1. EC2 Security Group
if [[ -n "${EXISTING_EC2_SG}" ]]; then
    EC2_SG_ID="${EXISTING_EC2_SG}"
    log_info "Reusing existing EC2 Security Group: ${EC2_SG_ID}"
else
    log_info "Creating EC2 Security Group (unque-ec2-sg)..."
    EC2_SG_ID=$(aws ec2 create-security-group \
        --group-name "unque-ec2-sg" \
        --description "Security group for UnQue 2.0 EC2 backend instance" \
        --vpc-id "${VPC_ID}" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=unque-ec2-sg},{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "GroupId" --output text)
    NEWLY_CREATED_RESOURCES+=("aws ec2 delete-security-group --group-id ${EC2_SG_ID}")
    log_pass "Created EC2 Security Group: ${EC2_SG_ID}"
fi

# Authorize SSH (port 22) from SSH_CIDR
HAS_SSH_RULE=$(aws ec2 describe-security-groups \
    --filters "Name=group-id,Values=${EC2_SG_ID}" \
              "Name=ip-permission.protocol,Values=tcp" \
              "Name=ip-permission.from-port,Values=22" \
              "Name=ip-permission.to-port,Values=22" \
              "Name=ip-permission.cidr,Values=${SSH_CIDR}" \
    --query "SecurityGroups[0].GroupId" \
    --output text)
[[ "${HAS_SSH_RULE}" == "None" ]] && HAS_SSH_RULE=""

if [[ -z "${HAS_SSH_RULE}" ]]; then
    log_info "Authorizing SSH (port 22) ingress from ${SSH_CIDR}..."
    aws ec2 authorize-security-group-ingress \
        --group-id "${EC2_SG_ID}" \
        --protocol tcp \
        --port 22 \
        --cidr "${SSH_CIDR}" >/dev/null
    log_pass "Authorized SSH access from ${SSH_CIDR}."
else
    log_info "SSH ingress rule for ${SSH_CIDR} already exists (skipping creation)."
fi

# Authorize App (port 5001) from APP_CIDR
HAS_APP_RULE=$(aws ec2 describe-security-groups \
    --filters "Name=group-id,Values=${EC2_SG_ID}" \
              "Name=ip-permission.protocol,Values=tcp" \
              "Name=ip-permission.from-port,Values=5001" \
              "Name=ip-permission.to-port,Values=5001" \
              "Name=ip-permission.cidr,Values=${APP_CIDR}" \
    --query "SecurityGroups[0].GroupId" \
    --output text)
[[ "${HAS_APP_RULE}" == "None" ]] && HAS_APP_RULE=""

if [[ -z "${HAS_APP_RULE}" ]]; then
    log_info "Authorizing App API (port 5001) ingress from ${APP_CIDR}..."
    aws ec2 authorize-security-group-ingress \
        --group-id "${EC2_SG_ID}" \
        --protocol tcp \
        --port 5001 \
        --cidr "${APP_CIDR}" >/dev/null
    log_pass "Authorized App API access from ${APP_CIDR}."
else
    log_info "App API ingress rule for ${APP_CIDR} already exists (skipping creation)."
fi

# 2. DocumentDB Security Group
if [[ -n "${EXISTING_DOCDB_SG}" ]]; then
    DOCDB_SG_ID="${EXISTING_DOCDB_SG}"
    log_info "Reusing existing DocumentDB Security Group: ${DOCDB_SG_ID}"
else
    log_info "Creating DocumentDB Security Group (unque-docdb-sg)..."
    DOCDB_SG_ID=$(aws ec2 create-security-group \
        --group-name "unque-docdb-sg" \
        --description "Security group for UnQue 2.0 DocumentDB cluster" \
        --vpc-id "${VPC_ID}" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=unque-docdb-sg},{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "GroupId" --output text)
    NEWLY_CREATED_RESOURCES+=("aws ec2 delete-security-group --group-id ${DOCDB_SG_ID}")
    log_pass "Created DocumentDB Security Group: ${DOCDB_SG_ID}"
fi

# Authorize TCP 27017 ONLY from the EC2 Security Group (checking referenced group ID)
HAS_DOCDB_RULE=$(aws ec2 describe-security-groups \
    --filters "Name=group-id,Values=${DOCDB_SG_ID}" \
              "Name=ip-permission.protocol,Values=tcp" \
              "Name=ip-permission.from-port,Values=27017" \
              "Name=ip-permission.to-port,Values=27017" \
              "Name=ip-permission.group-id,Values=${EC2_SG_ID}" \
    --query "SecurityGroups[0].GroupId" \
    --output text)
[[ "${HAS_DOCDB_RULE}" == "None" ]] && HAS_DOCDB_RULE=""

if [[ -z "${HAS_DOCDB_RULE}" ]]; then
    log_info "Authorizing DocumentDB port 27017 ingress ONLY from EC2 SG (${EC2_SG_ID})..."
    aws ec2 authorize-security-group-ingress \
        --group-id "${DOCDB_SG_ID}" \
        --protocol tcp \
        --port 27017 \
        --source-group "${EC2_SG_ID}" >/dev/null
    log_pass "Authorized DocumentDB port 27017 from EC2 Security Group."
else
    log_info "DocumentDB ingress rule from EC2 SG already exists (skipping creation)."
fi

# --- Step F: DocumentDB Subnet Group ---
DOCDB_SUBNET_GROUP_NAME="unque-docdb-subnet-group"

if [[ -n "${EXISTING_DOCDB_SUBNET_GROUP}" ]]; then
    log_info "Reusing existing DocumentDB Subnet Group: ${DOCDB_SUBNET_GROUP_NAME}"
else
    log_info "Creating DocumentDB Subnet Group with subnets ${PRIVATE_SUBNET_1_ID} (${AZ1}) and ${PRIVATE_SUBNET_2_ID} (${AZ2})..."
    aws docdb create-db-subnet-group \
        --db-subnet-group-name "${DOCDB_SUBNET_GROUP_NAME}" \
        --db-subnet-group-description "DocumentDB Subnet Group for UnQue 2.0" \
        --subnet-ids "${PRIVATE_SUBNET_1_ID}" "${PRIVATE_SUBNET_2_ID}" \
        --tags "Key=Name,Value=unque-docdb-subnet-group" "Key=Project,Value=${PROJECT_TAG}" >/dev/null
    NEWLY_CREATED_RESOURCES+=("aws docdb delete-db-subnet-group --db-subnet-group-name ${DOCDB_SUBNET_GROUP_NAME}")
    log_pass "Created DocumentDB Subnet Group: ${DOCDB_SUBNET_GROUP_NAME}"
fi

# ------------------------------------------------------------------------------
# 11. Save State to Local Environment File
# ------------------------------------------------------------------------------
mkdir -p "$(dirname "${STATE_FILE}")"
cat << EOF > "${STATE_FILE}"
# Auto-generated by scripts/01-network.sh on $(date -u +"%Y-%m-%d %H:%M:%SZ")
AWS_REGION="${AWS_REGION}"
VPC_ID="${VPC_ID}"
PUBLIC_SUBNET_ID="${PUBLIC_SUBNET_ID}"
PRIVATE_SUBNET_1_ID="${PRIVATE_SUBNET_1_ID}"
PRIVATE_SUBNET_2_ID="${PRIVATE_SUBNET_2_ID}"
AZ1="${AZ1}"
AZ2="${AZ2}"
IGW_ID="${IGW_ID}"
PUBLIC_RT_ID="${PUBLIC_RT_ID}"
EC2_SG_ID="${EC2_SG_ID}"
DOCDB_SG_ID="${DOCDB_SG_ID}"
DOCDB_SUBNET_GROUP_NAME="${DOCDB_SUBNET_GROUP_NAME}"
SSH_CIDR="${SSH_CIDR}"
APP_CIDR="${APP_CIDR}"
EOF

log_pass "Saved network state to ${STATE_FILE}."

# ------------------------------------------------------------------------------
# 12. Final Completion Banner
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  RESULT: Network provisioning completed successfully!          ${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "  VPC ID              : ${VPC_ID}"
echo -e "  Public Subnet       : ${PUBLIC_SUBNET_ID} (${AZ1})"
echo -e "  Private Subnet 1    : ${PRIVATE_SUBNET_1_ID} (${AZ1})"
echo -e "  Private Subnet 2    : ${PRIVATE_SUBNET_2_ID} (${AZ2})"
echo -e "  Internet Gateway    : ${IGW_ID}"
echo -e "  Public Route Table  : ${PUBLIC_RT_ID}"
echo -e "  EC2 Security Group  : ${EC2_SG_ID} (SSH: ${SSH_CIDR}, App: ${APP_CIDR})"
echo -e "  DocDB Security Group: ${DOCDB_SG_ID} (27017: ${EC2_SG_ID} only)"
echo -e "  DocDB Subnet Group  : ${DOCDB_SUBNET_GROUP_NAME}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
