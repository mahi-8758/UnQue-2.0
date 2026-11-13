#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/02-documentdb.sh
# Project: UnQue 2.0 - Campus Appointment Booking System
# Purpose: Provision an Amazon DocumentDB cluster and primary instance
#          compatible with MongoDB 5.0 in private subnets.
#
# Constraints & Architecture:
#   - Region: ap-south-1 (Mumbai)
#   - Engine: docdb version 5.0.0 (Instance-based cluster, NOT Elastic)
#   - Instance class: db.t3.medium (Single primary instance)
#   - Subnet Group: unque-docdb-subnet-group (Private subnets only)
#   - Security Group: unque-docdb-sg (Inbound port 27017 from EC2 SG only)
#   - Storage Encryption: Enabled (AWS managed KMS key)
#   - Deletion Protection: Enabled
#   - Backup Retention: 1 day
#   - Public Accessibility: false (Enforced by DocumentDB & VPC subnets)
#   - Zero credential leaks: Prompts via hidden input, temporary chmod 600 JSON,
#                           never prints passwords or logs them to Git.
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
echo "    UnQue 2.0 - DocumentDB Provisioning (MongoDB Compatible)    "
if [[ "${DRY_RUN}" == "true" ]]; then
    echo "       Region: ap-south-1 | Mode: DRY-RUN (Plan Only)           "
else
    echo "       Region: ap-south-1 | Mode: LIVE PROVISIONING             "
fi
echo "================================================================"

# Clear warning about AWS DocumentDB pricing (Requirement 24)
echo -e "${YELLOW}================================================================${NC}"
echo -e "${YELLOW} [BILLING NOTICE] Amazon DocumentDB is a paid AWS service.${NC}"
echo -e "${YELLOW} DocumentDB charges include instance-hours, storage, I/O and${NC}"
echo -e "${YELLOW} applicable backup costs. Check the official AWS pricing page for${NC}"
echo -e "${YELLOW} current regional rates in ap-south-1.${NC}"
echo -e "${YELLOW} Remember to stop or delete the instance when not actively testing${NC}"
echo -e "${YELLOW} to minimize AWS costs.${NC}"
echo -e "${YELLOW}================================================================${NC}\n"

# --- Step 1: Locate and Load Network Resources (Requirements 1, 2) ---
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

AWS_REGION="${AWS_REGION:-ap-south-1}"
CLUSTER_ID="unque-docdb"
INSTANCE_ID="unque-docdb-instance-1"
DB_INSTANCE_CLASS="db.t3.medium"
ENGINE="docdb"
ENGINE_VERSION="5.0.0"
DOCDB_PORT=27017
PROJECT_TAG="unque-2.0"
STATE_FILE="scripts/.docdb.env"

# Ensure all expected network identifiers are present
MISSING_VARS=()
[[ -z "${VPC_ID:-}" ]] && MISSING_VARS+=("VPC_ID")
[[ -z "${PRIVATE_SUBNET_1_ID:-}" ]] && MISSING_VARS+=("PRIVATE_SUBNET_1_ID")
[[ -z "${PRIVATE_SUBNET_2_ID:-}" ]] && MISSING_VARS+=("PRIVATE_SUBNET_2_ID")
[[ -z "${DOCDB_SG_ID:-}" ]] && MISSING_VARS+=("DOCDB_SG_ID")
[[ -z "${DOCDB_SUBNET_GROUP_NAME:-}" ]] && MISSING_VARS+=("DOCDB_SUBNET_GROUP_NAME")

if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
    log_fail "Missing required variables in ${RESOURCES_ENV}: ${MISSING_VARS[*]}"
    exit 1
fi

# Track resources created in this specific execution run (Requirement 22)
NEWLY_CREATED_RESOURCES=()

cleanup_on_exit() {
    local exit_code=$?
    # Clean up any temporary credentials file if left behind
    if [[ -n "${TMP_JSON:-}" && -f "${TMP_JSON}" ]]; then
        if command -v shred >/dev/null 2>&1; then
            shred -u "${TMP_JSON}" 2>/dev/null || rm -f "${TMP_JSON}"
        else
            rm -f "${TMP_JSON}"
        fi
    fi
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}" 2>/dev/null || true
    fi

    # Report failure without deleting pre-existing infrastructure
    if [[ ${exit_code} -ne 0 ]]; then
        echo -e "\n${RED}[ERROR] Script failed with exit code ${exit_code}.${NC}"
        if [[ ${#NEWLY_CREATED_RESOURCES[@]} -gt 0 ]]; then
            echo -e "${YELLOW}[WARNING] The following resources were initiated during this run before the error:${NC}"
            for cmd in "${NEWLY_CREATED_RESOURCES[@]}"; do
                echo -e "  - ${cmd}"
            done
            echo -e "${YELLOW}[NOTE] AWS rejects cluster deletion while deletion protection is enabled.${NC}"
            echo -e "${YELLOW}Disable it with '--no-deletion-protection' before deleting the cluster.${NC}"
            echo -e "${YELLOW}Pre-existing resources were NOT modified or deleted.${NC}"
        fi
    fi
}
trap cleanup_on_exit EXIT

# --- Step 2: Validate Existing Network Infrastructure in AWS (Requirement 3) ---
echo -e "\n${CYAN}Step 1: Validating prerequisite network infrastructure...${NC}"

# 1. Validate VPC
VALID_VPC=$(aws ec2 describe-vpcs \
    --region "${AWS_REGION}" \
    --vpc-ids "${VPC_ID}" \
    --query "Vpcs[0].VpcId" \
    --output text 2>/dev/null || true)
if [[ "${VALID_VPC}" != "${VPC_ID}" ]]; then
    log_fail "VPC '${VPC_ID}' does not exist or is inaccessible in ${AWS_REGION}."
    exit 1
fi
log_pass "VPC verified: ${VPC_ID}"

# 2. Validate Private Subnets
VALID_SUBNETS=$(aws ec2 describe-subnets \
    --region "${AWS_REGION}" \
    --subnet-ids "${PRIVATE_SUBNET_1_ID}" "${PRIVATE_SUBNET_2_ID}" \
    --query "Subnets[*].SubnetId" \
    --output text 2>/dev/null || true)
if ! echo "${VALID_SUBNETS}" | grep -qw "${PRIVATE_SUBNET_1_ID}" || ! echo "${VALID_SUBNETS}" | grep -qw "${PRIVATE_SUBNET_2_ID}"; then
    log_fail "One or both private subnets (${PRIVATE_SUBNET_1_ID}, ${PRIVATE_SUBNET_2_ID}) are missing in ${AWS_REGION}."
    exit 1
fi
log_pass "Private subnets verified: ${PRIVATE_SUBNET_1_ID}, ${PRIVATE_SUBNET_2_ID}"

# 3. Validate DocumentDB Security Group
VALID_SG=$(aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --group-ids "${DOCDB_SG_ID}" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || true)
if [[ "${VALID_SG}" != "${DOCDB_SG_ID}" ]]; then
    log_fail "DocumentDB Security Group '${DOCDB_SG_ID}' does not exist in ${AWS_REGION}."
    exit 1
fi
log_pass "DocumentDB Security Group verified: ${DOCDB_SG_ID}"

# 4. Validate DocumentDB Subnet Group and its VPC
read -r VALID_SUBNET_GROUP SUBNET_GROUP_VPC <<< "$(aws docdb describe-db-subnet-groups \
    --region "${AWS_REGION}" \
    --db-subnet-group-name "${DOCDB_SUBNET_GROUP_NAME}" \
    --query "DBSubnetGroups[0].[DBSubnetGroupName,VpcId]" \
    --output text 2>/dev/null || true)"

if [[ "${VALID_SUBNET_GROUP}" != "${DOCDB_SUBNET_GROUP_NAME}" ]]; then
    log_fail "DocumentDB Subnet Group '${DOCDB_SUBNET_GROUP_NAME}' does not exist in ${AWS_REGION}."
    exit 1
fi

if [[ "${SUBNET_GROUP_VPC}" != "${VPC_ID}" ]]; then
    log_fail "DocumentDB Subnet Group '${DOCDB_SUBNET_GROUP_NAME}' belongs to VPC '${SUBNET_GROUP_VPC}', but expected VPC is '${VPC_ID}'."
    exit 1
fi
log_pass "DocumentDB Subnet Group verified: ${DOCDB_SUBNET_GROUP_NAME} (VpcId: ${SUBNET_GROUP_VPC})"

# --- Step 3: Verify Engine Version & Orderable Instance Class (Requirement 7) ---
echo -e "\n${CYAN}Step 2: Checking DocumentDB engine v${ENGINE_VERSION} and instance availability...${NC}"

ORDERABLE_CLASSES=$(aws docdb describe-orderable-db-instance-options \
    --region "${AWS_REGION}" \
    --engine "${ENGINE}" \
    --engine-version "${ENGINE_VERSION}" \
    --query "OrderableDBInstanceOptions[*].DBInstanceClass" \
    --output text 2>/dev/null || true)

if [[ -z "${ORDERABLE_CLASSES}" ]]; then
    log_fail "No orderable instance options found for ${ENGINE} v${ENGINE_VERSION} in ${AWS_REGION}."
    exit 1
fi

IS_ORDERABLE=false
for cls in ${ORDERABLE_CLASSES}; do
    if [[ "${cls}" == "${DB_INSTANCE_CLASS}" ]]; then
        IS_ORDERABLE=true
        break
    fi
done

if [[ "${IS_ORDERABLE}" != "true" ]]; then
    log_fail "Instance class '${DB_INSTANCE_CLASS}' is NOT orderable for DocumentDB ${ENGINE_VERSION} in ${AWS_REGION}!"
    echo -e "${YELLOW}Supported instance classes for DocumentDB ${ENGINE_VERSION} in ${AWS_REGION}:${NC}"
    echo "${ORDERABLE_CLASSES}" | tr '\t' '\n' | sort -u | sed 's/^/  - /'
    echo -e "${RED}[ERROR] Refusing to silently select a larger/more expensive instance class. Provisioning stopped.${NC}"
    exit 1
fi
log_pass "Confirmed: '${DB_INSTANCE_CLASS}' is orderable for DocumentDB ${ENGINE_VERSION} in ${AWS_REGION}."

# --- Step 4: Inspect Existing Cluster and Instance (Requirement 20) ---
echo -e "\n${CYAN}Step 3: Checking for existing DocumentDB cluster and instances...${NC}"

EXISTING_CLUSTER=$(aws docdb describe-db-clusters \
    --region "${AWS_REGION}" \
    --query "DBClusters[?DBClusterIdentifier=='${CLUSTER_ID}'].DBClusterIdentifier | [0]" \
    --output text 2>/dev/null || true)
[[ "${EXISTING_CLUSTER}" == "None" ]] && EXISTING_CLUSTER=""

EXISTING_INSTANCE=""
EXISTING_ENDPOINT=""
EXISTING_PORT="27017"
EXISTING_USERNAME=""

if [[ -n "${EXISTING_CLUSTER}" ]]; then
    log_info "Found existing DocumentDB cluster: '${CLUSTER_ID}'. Validating configuration..."

    # Retrieve cluster properties
    read -r EX_ENGINE EX_VER EX_SUBGRP EX_ENC EX_DELPROT EX_STATUS EX_ENDPOINT EX_PORT EX_USER <<< "$(aws docdb describe-db-clusters \
        --region "${AWS_REGION}" \
        --db-cluster-identifier "${CLUSTER_ID}" \
        --query "DBClusters[0].[Engine,EngineVersion,DBSubnetGroup,StorageEncrypted,DeletionProtection,Status,Endpoint,Port,MasterUsername]" \
        --output text)"

    if [[ "${EX_ENGINE}" != "${ENGINE}" ]]; then
        log_fail "Existing cluster engine is '${EX_ENGINE}', expected '${ENGINE}'."
        exit 1
    fi
    if [[ ! "${EX_VER}" =~ ^5\. ]]; then
        log_fail "Existing cluster engine version is '${EX_VER}', expected 5.0.x."
        exit 1
    fi
    if [[ "${EX_SUBGRP}" != "${DOCDB_SUBNET_GROUP_NAME}" ]]; then
        log_fail "Existing cluster subnet group is '${EX_SUBGRP}', expected '${DOCDB_SUBNET_GROUP_NAME}'."
        exit 1
    fi
    if [[ "${EX_ENC}" != "True" && "${EX_ENC}" != "true" ]]; then
        log_fail "Existing cluster has storage encryption disabled. Encryption at rest is required."
        exit 1
    fi
    if [[ "${EX_DELPROT}" != "True" && "${EX_DELPROT}" != "true" ]]; then
        log_fail "Existing cluster '${CLUSTER_ID}' has deletion protection disabled. Deletion protection is required."
        log_info "Refusing to silently modify, delete, or recreate the existing cluster. Aborting."
        exit 1
    fi

    # Verify cluster security group includes DOCDB_SG_ID
    CLUSTER_SGS=$(aws docdb describe-db-clusters \
        --region "${AWS_REGION}" \
        --db-cluster-identifier "${CLUSTER_ID}" \
        --query "DBClusters[0].VpcSecurityGroups[*].VpcSecurityGroupId" \
        --output text)
    if ! echo "${CLUSTER_SGS}" | grep -qw "${DOCDB_SG_ID}"; then
        log_fail "Existing cluster security groups (${CLUSTER_SGS}) do not include expected SG: ${DOCDB_SG_ID}."
        exit 1
    fi

    EXISTING_ENDPOINT="${EX_ENDPOINT}"
    [[ -n "${EX_PORT}" && "${EX_PORT}" != "None" ]] && EXISTING_PORT="${EX_PORT}"
    [[ -n "${EX_USER}" && "${EX_USER}" != "None" ]] && EXISTING_USERNAME="${EX_USER}"

    log_pass "Existing cluster '${CLUSTER_ID}' validated successfully: Engine=${EX_ENGINE} ${EX_VER}, Status=${EX_STATUS}, Encrypted=true, DeletionProtection=true."

    # Check for primary instance
    EXISTING_INSTANCE=$(aws docdb describe-db-instances \
        --region "${AWS_REGION}" \
        --query "DBInstances[?DBInstanceIdentifier=='${INSTANCE_ID}'].DBInstanceIdentifier | [0]" \
        --output text 2>/dev/null || true)
    [[ "${EXISTING_INSTANCE}" == "None" ]] && EXISTING_INSTANCE=""

    if [[ -n "${EXISTING_INSTANCE}" ]]; then
        read -r INST_CLASS INST_STATUS INST_PUBLIC <<< "$(aws docdb describe-db-instances \
            --region "${AWS_REGION}" \
            --db-instance-identifier "${INSTANCE_ID}" \
            --query "DBInstances[0].[DBInstanceClass,DBInstanceStatus,PubliclyAccessible]" \
            --output text)"

        if [[ "${INST_PUBLIC}" == "True" || "${INST_PUBLIC}" == "true" ]]; then
            log_fail "Security violation: Instance '${INSTANCE_ID}' has PubliclyAccessible set to true!"
            exit 1
        fi
        log_pass "Existing instance '${INSTANCE_ID}' validated: Class=${INST_CLASS}, Status=${INST_STATUS}, PubliclyAccessible=false."
    else
        log_info "Cluster exists, but primary instance '${INSTANCE_ID}' does not exist yet. Will create instance."
    fi
else
    log_info "No existing cluster named '${CLUSTER_ID}' found. A new cluster and instance will be created."
fi

# --- Step 5: Execution Plan Summary & Dry-Run Exit (Requirement 18) ---
echo -e "\n--- Execution Plan Summary ---"
echo "  Region                 : ${AWS_REGION}"
echo "  Cluster Identifier     : ${CLUSTER_ID}"
echo "  Primary Instance ID    : ${INSTANCE_ID}"
echo "  Instance Class         : ${DB_INSTANCE_CLASS} (Single Primary Instance)"
echo "  Engine Type & Version  : ${ENGINE} (Amazon DocumentDB 5.0, Instance-based)"
echo "  Subnet Group           : ${DOCDB_SUBNET_GROUP_NAME} (Private subnets only)"
echo "  Security Group         : ${DOCDB_SG_ID} (TCP 27017 from EC2 SG only)"
echo "  Storage Encryption     : true (KMS AWS Managed Key)"
echo "  Deletion Protection    : true"
echo "  Backup Retention       : 1 day"
echo "  Public Accessibility   : false (Private VPC Only)"
if [[ -n "${EXISTING_CLUSTER}" ]]; then
    echo "  Cluster Action         : REUSE existing cluster (${CLUSTER_ID})"
else
    echo "  Cluster Action         : CREATE new cluster (${CLUSTER_ID})"
fi
if [[ -n "${EXISTING_INSTANCE}" ]]; then
    echo "  Instance Action        : REUSE existing instance (${INSTANCE_ID})"
else
    echo "  Instance Action        : CREATE new instance (${INSTANCE_ID})"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "\n${GREEN}[PASS] Dry-run complete. All prerequisite checks passed.${NC}"
    echo -e "${GREEN}No AWS resources were created, modified, or deleted.${NC}"
    exit 0
fi

# --- Step 6: User Confirmation (Requirement 19) ---
echo -e "\n${YELLOW}================================================================${NC}"
echo -e "${YELLOW}Confirmation Required:${NC}"
echo -e "You are about to provision an Amazon DocumentDB cluster in region '${AWS_REGION}'."
echo -e "This will incur charges on your AWS account while the instance runs."
echo -e "${YELLOW}================================================================${NC}"
read -r -p "Do you want to proceed with provisioning? [y/N]: " USER_CONFIRM
if [[ ! "${USER_CONFIRM}" =~ ^[Yy]$ ]]; then
    log_info "Provisioning aborted by user. Exiting."
    exit 0
fi

# --- Step 7: Credential Input and Validation (Requirements 12, 13, 14) ---
DB_USERNAME=""
DB_PASSWORD=""

if [[ -z "${EXISTING_CLUSTER}" ]]; then
    echo -e "\n${CYAN}--- DocumentDB Master Credentials Setup ---${NC}"
    echo "Master credentials must satisfy AWS DocumentDB constraints:"
    echo "  - Username: 1-63 letters or numbers, must begin with a letter, no reserved words."
    echo "  - Password: 8-100 printable ASCII characters; at least 3 categories (upper, lower, digit, symbol)."
    echo "  - Password cannot contain: slash (/), double-quote (\"), at-sign (@), backtick (\`), or spaces."

    # 1. Master Username Prompt & Validation
    while true; do
        read -r -p "Enter DocumentDB Master Username [default: docdbadmin]: " INPUT_USER
        DB_USERNAME="${INPUT_USER:-docdbadmin}"

        if [[ ${#DB_USERNAME} -lt 1 || ${#DB_USERNAME} -gt 63 ]]; then
            log_fail "Username must be between 1 and 63 characters."
            continue
        fi
        if [[ ! "${DB_USERNAME}" =~ ^[a-zA-Z][a-zA-Z0-9]*$ ]]; then
            log_fail "Username must start with a letter and contain only alphanumeric characters."
            continue
        fi
        LOWER_USER=$(echo "${DB_USERNAME}" | tr '[:upper:]' '[:lower:]')
        if [[ "${LOWER_USER}" == "admin" || "${LOWER_USER}" == "root" || "${LOWER_USER}" == "system" || "${LOWER_USER}" == "administrator" ]]; then
            log_fail "'${DB_USERNAME}' is a reserved database engine keyword. Please select another username."
            continue
        fi
        break
    done

    # 2. Master Password Prompt & Validation (Hidden input, no shell history)
    while true; do
        read -r -s -p "Enter DocumentDB Master Password: " DB_PASSWORD
        echo ""
        if [[ -z "${DB_PASSWORD}" ]]; then
            log_fail "Password cannot be empty."
            continue
        fi

        PASS_LEN=${#DB_PASSWORD}
        if [[ ${PASS_LEN} -lt 8 || ${PASS_LEN} -gt 100 ]]; then
            log_fail "Password must be between 8 and 100 characters (entered ${PASS_LEN})."
            continue
        fi

        if [[ "${DB_PASSWORD}" =~ [/\"@[:space:]\`] ]]; then
            log_fail "Password cannot contain slash (/), quote (\"), at-sign (@), backtick (\`), or spaces."
            continue
        fi

        HAS_UPPER=0
        HAS_LOWER=0
        HAS_NUM=0
        HAS_PUNCT=0
        [[ "${DB_PASSWORD}" =~ [A-Z] ]] && HAS_UPPER=1
        [[ "${DB_PASSWORD}" =~ [a-z] ]] && HAS_LOWER=1
        [[ "${DB_PASSWORD}" =~ [0-9] ]] && HAS_NUM=1
        [[ "${DB_PASSWORD}" =~ [^A-Za-z0-9] ]] && HAS_PUNCT=1

        CLASS_COUNT=$(( HAS_UPPER + HAS_LOWER + HAS_NUM + HAS_PUNCT ))
        if [[ ${CLASS_COUNT} -lt 3 ]]; then
            log_fail "Password must contain at least 3 of: uppercase, lowercase, numbers, punctuation symbols."
            continue
        fi

        read -r -s -p "Confirm DocumentDB Master Password: " DB_PASSWORD_CONFIRM
        echo ""
        if [[ "${DB_PASSWORD}" != "${DB_PASSWORD_CONFIRM}" ]]; then
            log_fail "Passwords do not match. Please try again."
            continue
        fi

        log_pass "Master credentials accepted and validated."
        break
    done
else
    DB_USERNAME="${EXISTING_USERNAME:-docdbadmin}"
    log_info "Using existing cluster's configured master username: ${DB_USERNAME}"
fi

# --- Step 8: Provision DocumentDB Cluster (Requirements 4, 5, 8, 9, 10, 11, 15, 21) ---
if [[ -z "${EXISTING_CLUSTER}" ]]; then
    echo -e "\n${CYAN}Step 4: Creating Amazon DocumentDB Cluster '${CLUSTER_ID}'...${NC}"

    # Create temporary JSON input file with restricted permissions (0600)
    TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'docdb_tmp')
    TMP_JSON="${TMP_DIR}/docdb_cluster_input.json"
    touch "${TMP_JSON}"
    chmod 600 "${TMP_JSON}"

    # Safely escape backslashes in password for JSON encoding
    ESCAPED_PASSWORD="${DB_PASSWORD//\\/\\\\}"

    cat <<EOF > "${TMP_JSON}"
{
    "DBClusterIdentifier": "${CLUSTER_ID}",
    "Engine": "${ENGINE}",
    "EngineVersion": "${ENGINE_VERSION}",
    "MasterUsername": "${DB_USERNAME}",
    "MasterUserPassword": "${ESCAPED_PASSWORD}",
    "DBSubnetGroupName": "${DOCDB_SUBNET_GROUP_NAME}",
    "VpcSecurityGroupIds": [
        "${DOCDB_SG_ID}"
    ],
    "StorageEncrypted": true,
    "DeletionProtection": true,
    "BackupRetentionPeriod": 1,
    "Tags": [
        {"Key": "Name", "Value": "${CLUSTER_ID}"},
        {"Key": "Project", "Value": "${PROJECT_TAG}"}
    ]
}
EOF

    # Verify temporary file exists and is non-empty before calling AWS CLI
    if [[ ! -s "${TMP_JSON}" ]]; then
        log_fail "Failed to create temporary parameter file: ${TMP_JSON}"
        exit 1
    fi

    # Convert POSIX path to Windows-compatible absolute path for AWS CLI under Git Bash
    CLI_JSON_PATH="${TMP_JSON}"
    if command -v cygpath >/dev/null 2>&1; then
        CLI_JSON_PATH=$(cygpath -m "${TMP_JSON}")
    fi

    log_info "Calling AWS CLI create-db-cluster via secure temporary input file..."
    aws docdb create-db-cluster \
        --region "${AWS_REGION}" \
        --cli-input-json "file://${CLI_JSON_PATH}" >/dev/null

    # Track newly created cluster for safe error reporting
    # Note: AWS rejects cluster deletion while deletion protection is enabled.
    # Disable it with '--no-deletion-protection' before deleting the cluster.
    NEWLY_CREATED_RESOURCES+=("aws docdb modify-db-cluster --region ${AWS_REGION} --db-cluster-identifier ${CLUSTER_ID} --no-deletion-protection && aws docdb delete-db-cluster --region ${AWS_REGION} --db-cluster-identifier ${CLUSTER_ID} --skip-final-snapshot")
    log_pass "DocumentDB cluster creation initiated."

    # Immediately shred and remove the temporary JSON file containing the master password
    if command -v shred >/dev/null 2>&1; then
        shred -u "${TMP_JSON}" 2>/dev/null || rm -f "${TMP_JSON}"
    else
        rm -f "${TMP_JSON}"
    fi
    rm -rf "${TMP_DIR}" 2>/dev/null || true
    unset TMP_JSON TMP_DIR CLI_JSON_PATH ESCAPED_PASSWORD DB_PASSWORD DB_PASSWORD_CONFIRM

    # Wait until the cluster is available (Requirement 21)
    log_info "Waiting for DocumentDB cluster '${CLUSTER_ID}' to become available (typically 3-6 minutes)..."
    while true; do
        CLUSTER_STATUS=$(aws docdb describe-db-clusters \
            --region "${AWS_REGION}" \
            --db-cluster-identifier "${CLUSTER_ID}" \
            --query "DBClusters[0].Status" \
            --output text 2>/dev/null || true)

        if [[ "${CLUSTER_STATUS}" == "available" ]]; then
            log_pass "DocumentDB cluster '${CLUSTER_ID}' is now available!"
            break
        elif [[ "${CLUSTER_STATUS}" == "failed" || "${CLUSTER_STATUS}" == "incompatible-network" ]]; then
            log_fail "DocumentDB cluster entered terminal error state: ${CLUSTER_STATUS}"
            exit 1
        fi
        log_info "Cluster status: ${CLUSTER_STATUS}... waiting 15 seconds"
        sleep 15
    done
fi

# Retrieve cluster endpoint and port
CLUSTER_ENDPOINT=$(aws docdb describe-db-clusters \
    --region "${AWS_REGION}" \
    --db-cluster-identifier "${CLUSTER_ID}" \
    --query "DBClusters[0].Endpoint" \
    --output text)
CLUSTER_PORT=$(aws docdb describe-db-clusters \
    --region "${AWS_REGION}" \
    --db-cluster-identifier "${CLUSTER_ID}" \
    --query "DBClusters[0].Port" \
    --output text)

# --- Step 9: Provision Primary DB Instance (Requirements 6, 21) ---
if [[ -z "${EXISTING_INSTANCE}" ]]; then
    echo -e "\n${CYAN}Step 5: Creating DocumentDB Primary Instance '${INSTANCE_ID}' (${DB_INSTANCE_CLASS})...${NC}"

    aws docdb create-db-instance \
        --region "${AWS_REGION}" \
        --db-instance-identifier "${INSTANCE_ID}" \
        --db-cluster-identifier "${CLUSTER_ID}" \
        --db-instance-class "${DB_INSTANCE_CLASS}" \
        --engine "${ENGINE}" \
        --tags "Key=Name,Value=${INSTANCE_ID}" "Key=Project,Value=${PROJECT_TAG}" >/dev/null

    NEWLY_CREATED_RESOURCES+=("aws docdb delete-db-instance --region ${AWS_REGION} --db-instance-identifier ${INSTANCE_ID}")
    log_pass "Primary DB instance creation initiated."

    # Wait until the DB instance is available (Requirement 21)
    log_info "Waiting for DocumentDB instance '${INSTANCE_ID}' to become available (typically 3-8 minutes)..."
    while true; do
        INSTANCE_STATUS=$(aws docdb describe-db-instances \
            --region "${AWS_REGION}" \
            --db-instance-identifier "${INSTANCE_ID}" \
            --query "DBInstances[0].DBInstanceStatus" \
            --output text 2>/dev/null || true)

        if [[ "${INSTANCE_STATUS}" == "available" ]]; then
            log_pass "DocumentDB instance '${INSTANCE_ID}' is now available!"
            break
        elif [[ "${INSTANCE_STATUS}" == "failed" || "${INSTANCE_STATUS}" == "incompatible-parameters" ]]; then
            log_fail "DocumentDB instance entered terminal error state: ${INSTANCE_STATUS}"
            exit 1
        fi
        log_info "Instance status: ${INSTANCE_STATUS}... waiting 15 seconds"
        sleep 15
    done
else
    log_info "Reusing existing primary instance: ${EXISTING_INSTANCE}"
fi

# --- Step 10: Save Credentials/State File (Requirements 16, 17) ---
echo -e "\n${CYAN}Step 6: Saving cluster state to ${STATE_FILE}...${NC}"

# Create state file with restrictive user-only permissions (0600)
touch "${STATE_FILE}"
chmod 600 "${STATE_FILE}" 2>/dev/null || true

cat <<EOF > "${STATE_FILE}"
# Auto-generated by scripts/02-documentdb.sh on $(date -u +"%Y-%m-%d %H:%M:%SZ")
# NOTE: Master password is NOT stored here to prevent credential exposure.
AWS_REGION="${AWS_REGION}"
DOCDB_CLUSTER_ID="${CLUSTER_ID}"
DOCDB_INSTANCE_ID="${INSTANCE_ID}"
DOCDB_INSTANCE_CLASS="${DB_INSTANCE_CLASS}"
DOCDB_ENGINE_VERSION="${ENGINE_VERSION}"
DOCDB_ENDPOINT="${CLUSTER_ENDPOINT}"
DOCDB_PORT="${CLUSTER_PORT}"
DOCDB_MASTER_USERNAME="${DB_USERNAME}"
EOF

chmod 600 "${STATE_FILE}" 2>/dev/null || true
log_pass "Saved DocumentDB state to ${STATE_FILE} (permissions: 0600)."

# Also update scripts/.aws-resources.env with DocumentDB endpoint details
if [[ -f "${RESOURCES_ENV}" ]]; then
    sed -i '/^DOCDB_CLUSTER_ID=/d' "${RESOURCES_ENV}" 2>/dev/null || true
    sed -i '/^DOCDB_INSTANCE_ID=/d' "${RESOURCES_ENV}" 2>/dev/null || true
    sed -i '/^DOCDB_ENDPOINT=/d' "${RESOURCES_ENV}" 2>/dev/null || true
    sed -i '/^DOCDB_PORT=/d' "${RESOURCES_ENV}" 2>/dev/null || true
    sed -i '/^DOCDB_MASTER_USERNAME=/d' "${RESOURCES_ENV}" 2>/dev/null || true
    cat <<EOF >> "${RESOURCES_ENV}"
DOCDB_CLUSTER_ID="${CLUSTER_ID}"
DOCDB_INSTANCE_ID="${INSTANCE_ID}"
DOCDB_ENDPOINT="${CLUSTER_ENDPOINT}"
DOCDB_PORT="${CLUSTER_PORT}"
DOCDB_MASTER_USERNAME="${DB_USERNAME}"
EOF
    log_pass "Appended DocumentDB endpoint to ${RESOURCES_ENV}."
fi

# --- Step 11: Final Summary Output (Requirements 23, 24) ---
echo -e "\n================================================================"
echo -e "       DocumentDB Provisioning Completed Successfully           "
echo -e "================================================================"
echo -e "  AWS Region         : ${AWS_REGION}"
echo -e "  Cluster Identifier : ${CLUSTER_ID}"
echo -e "  Instance Identifier: ${INSTANCE_ID}"
echo -e "  Instance Class     : ${DB_INSTANCE_CLASS}"
echo -e "  Engine Version     : ${ENGINE_VERSION}"
echo -e "  Cluster Endpoint   : ${CLUSTER_ENDPOINT}"
echo -e "  Cluster Port       : ${CLUSTER_PORT}"
echo -e "  Master Username    : ${DB_USERNAME}"
echo -e "  Storage Encrypted  : true (KMS AWS Managed Key)"
echo -e "  Public Access      : false (Private VPC Subnets Only)"
echo -e "  State File         : ${STATE_FILE} (chmod 600, excluded from git)"
echo -e "================================================================"
echo -e "  Connection URI Format for Node.js Application:"
echo -e "  mongodb://${DB_USERNAME}:<PASSWORD>@${CLUSTER_ENDPOINT}:${CLUSTER_PORT}/unque?tls=true&tlsCAFile=global-bundle.pem&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false"
echo -e "================================================================"
echo -e "${YELLOW}  [COST REMINDER] DocumentDB runs on an hourly billing model.${NC}"
echo -e "${YELLOW}  Charges include instance-hours, storage, I/O and backup costs.${NC}"
echo -e "${YELLOW}  Check the official AWS pricing page for current regional rates.${NC}"
echo -e "${YELLOW}  Stop the instance when idle using AWS Console or CLI:${NC}"
echo -e "${YELLOW}  aws docdb stop-db-cluster --db-cluster-identifier ${CLUSTER_ID}${NC}"
echo -e "${YELLOW}  [NOTE] AWS rejects cluster deletion while deletion protection is enabled.${NC}"
echo -e "${YELLOW}  Disable it with '--no-deletion-protection' before deleting the cluster:${NC}"
echo -e "${YELLOW}  aws docdb modify-db-cluster --db-cluster-identifier ${CLUSTER_ID} --no-deletion-protection${NC}"
echo -e "================================================================\n"
