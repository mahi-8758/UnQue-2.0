#!/usr/bin/env bash

# ==============================================================================
# Script: scripts/00-preflight.sh
# Purpose: Preflight checks for UnQue 2.0 AWS deployment in ap-south-1 (Mumbai).
#          - Verifies installation of AWS CLI, Node.js, and npm.
#          - Validates AWS credentials using STS (Security Token Service).
#          - Verifies target region is configured as ap-south-1.
#          - Displays AWS Account ID and IAM identity (no secrets/passwords).
#
# IMPORTANT: This script is strictly read-only. It does NOT create, modify,
#            or delete any AWS resources.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration: Target AWS Region
# ------------------------------------------------------------------------------
REQUIRED_REGION="ap-south-1"

# Set AWS region environment variables for current execution session
export AWS_REGION="${REQUIRED_REGION}"
export AWS_DEFAULT_REGION="${REQUIRED_REGION}"

# Text color formatting
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
BOLD="\033[1m"
NC="\033[0m" # No Color

echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}        UnQue 2.0 - AWS Deployment Preflight Check              ${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo ""

# Track failures across all checks
FAILED_CHECKS=0

# Helper function to print PASS message
print_pass() {
    local message="$1"
    echo -e "  [${GREEN}${BOLD}PASS${NC}] ${message}"
}

# Helper function to print FAIL message
print_fail() {
    local message="$1"
    echo -e "  [${RED}${BOLD}FAIL${NC}] ${message}"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
}

# ------------------------------------------------------------------------------
# Check 1: AWS CLI Installation
# ------------------------------------------------------------------------------
echo -e "${BOLD}1. Checking AWS CLI Installation...${NC}"
if command -v aws >/dev/null 2>&1; then
    AWS_VERSION=$(aws --version 2>&1 | head -n 1)
    print_pass "AWS CLI is installed: ${AWS_VERSION}"
else
    print_fail "AWS CLI is not installed or not found in system PATH."
    echo "         Please install AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
fi
echo ""

# ------------------------------------------------------------------------------
# Check 2: AWS Credentials & STS Caller Identity
# ------------------------------------------------------------------------------
echo -e "${BOLD}2. Checking AWS Credentials via STS Caller Identity...${NC}"
if command -v aws >/dev/null 2>&1; then
    # Test credentials using 'aws sts get-caller-identity'
    if CALLER_JSON=$(aws sts get-caller-identity --output json 2>/dev/null); then
        # Safely extract Account and Arn using AWS CLI query (no secrets printed)
        AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || echo "Unknown")
        AWS_IAM_ARN=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null || echo "Unknown")

        print_pass "AWS credentials are valid."
        echo "         - AWS Account ID : ${AWS_ACCOUNT_ID}"
        echo "         - IAM Identity   : ${AWS_IAM_ARN}"
    else
        print_fail "AWS credentials are invalid, expired, or not configured."
        echo "         Run 'aws configure' or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY."
    fi
else
    print_fail "Skipping credential check because AWS CLI is not installed."
fi
echo ""

# ------------------------------------------------------------------------------
# Check 3: AWS Region Verification (ap-south-1)
# ------------------------------------------------------------------------------
echo -e "${BOLD}3. Verifying AWS Region Configuration...${NC}"
if command -v aws >/dev/null 2>&1; then
    CONFIGURED_REGION=$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION}")

    if [[ "${CONFIGURED_REGION}" == "${REQUIRED_REGION}" ]]; then
        print_pass "Configured region matches target: ${CONFIGURED_REGION}"
    else
        print_fail "Configured region is '${CONFIGURED_REGION}', expected '${REQUIRED_REGION}'."
        echo "         Run 'aws configure set region ${REQUIRED_REGION}' to update default region."
    fi
else
    print_fail "Skipping region verification because AWS CLI is not installed."
fi
echo ""

# ------------------------------------------------------------------------------
# Check 4: Node.js Installation & Version
# ------------------------------------------------------------------------------
echo -e "${BOLD}4. Checking Node.js Installation...${NC}"
if command -v node >/dev/null 2>&1; then
    NODE_VERSION=$(node -v 2>&1)
    print_pass "Node.js is installed: ${NODE_VERSION}"
else
    print_fail "Node.js is not installed or not found in system PATH."
    echo "         Please install Node.js (v18 or v20 LTS recommended)."
fi
echo ""

# ------------------------------------------------------------------------------
# Check 5: npm Installation & Version
# ------------------------------------------------------------------------------
echo -e "${BOLD}5. Checking npm Installation...${NC}"
if command -v npm >/dev/null 2>&1; then
    NPM_VERSION=$(npm -v 2>&1)
    print_pass "npm is installed: v${NPM_VERSION}"
else
    print_fail "npm is not installed or not found in system PATH."
fi
echo ""

# ------------------------------------------------------------------------------
# Final Preflight Summary
# ------------------------------------------------------------------------------
echo -e "${BLUE}${BOLD}================================================================${NC}"
if [[ ${FAILED_CHECKS} -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  RESULT: All preflight checks PASSED successfully!${NC}"
    echo -e "  Environment is ready for UnQue 2.0 AWS deployment in ${REQUIRED_REGION}."
    echo -e "${BLUE}${BOLD}================================================================${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}  RESULT: ${FAILED_CHECKS} preflight check(s) FAILED.${NC}"
    echo -e "  Please resolve the failed checks above before proceeding."
    echo -e "${BLUE}${BOLD}================================================================${NC}"
    exit 1
fi
