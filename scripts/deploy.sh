#!/usr/bin/env bash
# =============================================================================
# DRS Agent Lifecycle Automation - Full Deployment Script
# =============================================================================
# Deploys all infrastructure: IAM role, SSM documents, EventBridge rules,
# State Manager association, and Parameter Store entries.
#
# Prerequisites:
#   - AWS CLI v2 configured with appropriate permissions
#   - yq (https://github.com/mikefarah/yq) for YAML parsing, OR edit variables below
#
# Usage:
#   chmod +x scripts/deploy.sh
#   ./scripts/deploy.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (reads from config.yaml if yq is available, else uses defaults)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_DIR/config.yaml"

if command -v yq &> /dev/null && [ -f "$CONFIG_FILE" ]; then
  SOURCE_REGION=$(yq '.source_region' "$CONFIG_FILE")
  DR_REGION=$(yq '.dr_region' "$CONFIG_FILE")
  ACCOUNT_ID=$(yq '.account_id' "$CONFIG_FILE")
  SNS_TOPIC_NAME=$(yq '.sns_topic_name' "$CONFIG_FILE")
  AUDIT_BUCKET=$(yq '.audit_bucket_name' "$CONFIG_FILE")
  AUTO_INSTALL=$(yq '.auto_install_enabled' "$CONFIG_FILE")
  AUTO_OFFBOARD=$(yq '.auto_offboard_enabled' "$CONFIG_FILE")
  IAM_STACK=$(yq '.iam_stack_name' "$CONFIG_FILE")
  EB_SOURCE_STACK=$(yq '.eventbridge_source_stack_name' "$CONFIG_FILE")
  EB_DR_STACK=$(yq '.eventbridge_dr_stack_name' "$CONFIG_FILE")
  SM_STACK=$(yq '.state_manager_stack_name' "$CONFIG_FILE")
  DR_TAG_KEY=$(yq '.dr_tag_key' "$CONFIG_FILE")
  DR_PROTECTED_VALUE=$(yq '.dr_protected_value' "$CONFIG_FILE")
  STAND_DOWN_PARAM=$(yq '.stand_down_parameter' "$CONFIG_FILE")
  SCHEDULE_RATE=$(yq '.schedule_rate' "$CONFIG_FILE")
else
  echo "⚠️  yq not found or config.yaml missing. Using default values."
  echo "   Install yq: brew install yq (macOS) or snap install yq (Linux)"
  SOURCE_REGION="us-west-1"
  DR_REGION="us-east-2"
  ACCOUNT_ID="123456789012"
  SNS_TOPIC_NAME="drs-alerts"
  AUDIT_BUCKET=""
  AUTO_INSTALL="false"
  AUTO_OFFBOARD="false"
  IAM_STACK="drs-automation-iam"
  EB_SOURCE_STACK="drs-eventbridge-source"
  EB_DR_STACK="drs-eventbridge-dr"
  SM_STACK="drs-state-manager"
  DR_TAG_KEY="DR"
  DR_PROTECTED_VALUE="yes"
  STAND_DOWN_PARAM="/drs/control/event-in-progress"
  SCHEDULE_RATE="rate(30 minutes)"
fi

SNS_TOPIC_ARN="arn:aws:sns:${SOURCE_REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}"

echo "=============================================="
echo " DRS Agent Lifecycle Automation - Deployment"
echo "=============================================="
echo ""
echo "  Source Region:  $SOURCE_REGION"
echo "  DR Region:      $DR_REGION"
echo "  Account ID:     $ACCOUNT_ID"
echo "  Auto-Install:   $AUTO_INSTALL"
echo "  Auto-Offboard:  $AUTO_OFFBOARD"
echo "  SNS Topic:      $SNS_TOPIC_ARN"
echo "  Audit Bucket:   ${AUDIT_BUCKET:-'(disabled)'}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Deploy IAM Role
# ---------------------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1/6: Deploying IAM Role..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

aws cloudformation deploy \
  --template-file "$REPO_DIR/templates/iam-roles.yaml" \
  --stack-name "$IAM_STACK" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$SOURCE_REGION" \
  --parameter-overrides \
    AccountId="$ACCOUNT_ID" \
    SourceRegion="$SOURCE_REGION" \
    DRRegion="$DR_REGION" \
    AuditBucketName="$AUDIT_BUCKET" \
    SNSTopicName="$SNS_TOPIC_NAME" \
  --no-fail-on-empty-changeset

ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$IAM_STACK" \
  --region "$SOURCE_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' \
  --output text)

echo "✅ IAM Role deployed: $ROLE_ARN"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Register SSM Documents
# ---------------------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2/6: Registering SSM Automation Documents..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

"$SCRIPT_DIR/register-documents.sh"
echo ""

# ---------------------------------------------------------------------------
# Step 3: Deploy EventBridge Rules (Source Region)
# ---------------------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3/6: Deploying EventBridge Rules (Source Region)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

aws cloudformation deploy \
  --template-file "$REPO_DIR/templates/eventbridge-source.yaml" \
  --stack-name "$EB_SOURCE_STACK" \
  --region "$SOURCE_REGION" \
  --parameter-overrides \
    AutomationRoleArn="$ROLE_ARN" \
    TargetRegion="$DR_REGION" \
    DrTagKey="$DR_TAG_KEY" \
    SNSTopicArn="$SNS_TOPIC_ARN" \
    AuditBucket="$AUDIT_BUCKET" \
    AutoOffboardEnabled="$AUTO_OFFBOARD" \
  --no-fail-on-empty-changeset

echo "✅ EventBridge source rules deployed"
echo ""

# ---------------------------------------------------------------------------
# Step 4: Deploy EventBridge Rule (DR Region)
# ---------------------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4/6: Deploying EventBridge Rule (DR Region)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

aws cloudformation deploy \
  --template-file "$REPO_DIR/templates/eventbridge-dr.yaml" \
  --stack-name "$EB_DR_STACK" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$DR_REGION" \
  --parameter-overrides \
    SourceRegion="$SOURCE_REGION" \
    AccountId="$ACCOUNT_ID" \
  --no-fail-on-empty-changeset

echo "✅ EventBridge DR forwarding rule deployed"
echo ""

# ---------------------------------------------------------------------------
# Step 5: Initialize Parameter Store
# ---------------------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5/6: Initializing Parameter Store..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

"$SCRIPT_DIR/init-parameters.sh"
echo ""

# ---------------------------------------------------------------------------
# Step 6: Deploy State Manager Association
# ---------------------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6/6: Deploying State Manager Association..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

aws cloudformation deploy \
  --template-file "$REPO_DIR/templates/state-manager-association.yaml" \
  --stack-name "$SM_STACK" \
  --region "$SOURCE_REGION" \
  --parameter-overrides \
    AutomationRoleArn="$ROLE_ARN" \
    TargetRegion="$DR_REGION" \
    ScheduleRate="$SCHEDULE_RATE" \
    AutoInstallEnabled="$AUTO_INSTALL" \
    DrTagKey="$DR_TAG_KEY" \
    DrProtectedValue="$DR_PROTECTED_VALUE" \
    SNSTopicArn="$SNS_TOPIC_ARN" \
    AuditBucket="$AUDIT_BUCKET" \
    StandDownParameter="$STAND_DOWN_PARAM" \
  --no-fail-on-empty-changeset

echo "✅ State Manager association deployed"
echo ""

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
echo "=============================================="
echo " Deployment Complete - Verification"
echo "=============================================="
echo ""
echo "CloudFormation Stacks:"
for STACK in "$IAM_STACK" "$EB_SOURCE_STACK" "$SM_STACK"; do
  STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" \
    --region "$SOURCE_REGION" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "NOT_FOUND")
  echo "  [$SOURCE_REGION] $STACK: $STATUS"
done

DR_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$EB_DR_STACK" \
  --region "$DR_REGION" \
  --query 'Stacks[0].StackStatus' \
  --output text 2>/dev/null || echo "NOT_FOUND")
echo "  [$DR_REGION] $EB_DR_STACK: $DR_STATUS"

echo ""
echo "SSM Documents:"
for DOC in DRS-Agent-Onboard DRS-Agent-Heal DRS-Agent-Offboard; do
  DOC_STATUS=$(aws ssm describe-document \
    --name "$DOC" \
    --region "$SOURCE_REGION" \
    --query 'Document.Status' \
    --output text 2>/dev/null || echo "NOT_FOUND")
  echo "  $DOC: $DOC_STATUS"
done

echo ""
echo "Parameter Store:"
PARAM_VAL=$(aws ssm get-parameter \
  --name "$STAND_DOWN_PARAM" \
  --region "$SOURCE_REGION" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "NOT_SET")
echo "  $STAND_DOWN_PARAM = $PARAM_VAL"

echo ""
echo "=============================================="
echo " ✅ Deployment successful!"
echo ""
echo " Next steps:"
echo "   1. Tag an instance with DR=yes to test onboarding"
echo "   2. Monitor in CloudWatch namespace: DRSAutomation"
echo "   3. When ready, set auto_install_enabled=true in config.yaml"
echo "      and re-deploy the State Manager stack"
echo "=============================================="