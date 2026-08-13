#!/usr/bin/env bash
# =============================================================================
# DRS Agent Lifecycle Automation - Register SSM Automation Documents
# =============================================================================
# Creates or updates the three SSM Automation documents.
# Idempotent: uses create-document on first run, update-document-default-version
# on subsequent runs.
#
# Usage:
#   chmod +x scripts/register-documents.sh
#   ./scripts/register-documents.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_DIR/config.yaml"

# Read region from config or default
if command -v yq &> /dev/null && [ -f "$CONFIG_FILE" ]; then
  SOURCE_REGION=$(yq '.source_region' "$CONFIG_FILE")
else
  SOURCE_REGION="${SOURCE_REGION:-us-west-1}"
fi

DOCUMENTS_DIR="$REPO_DIR/documents"

# Document name → file mapping
declare -A DOCS=(
  ["DRS-Agent-Onboard"]="$DOCUMENTS_DIR/DRS-Agent-Onboard.yaml"
  ["DRS-Agent-Heal"]="$DOCUMENTS_DIR/DRS-Agent-Heal.yaml"
  ["DRS-Agent-Offboard"]="$DOCUMENTS_DIR/DRS-Agent-Offboard.yaml"
)

echo "Registering SSM Automation documents in $SOURCE_REGION..."
echo ""

for DOC_NAME in "${!DOCS[@]}"; do
  DOC_FILE="${DOCS[$DOC_NAME]}"

  if [ ! -f "$DOC_FILE" ]; then
    echo "❌ ERROR: Document file not found: $DOC_FILE"
    exit 1
  fi

  echo "  📄 $DOC_NAME"
  echo "     File: $DOC_FILE"

  # Check if document already exists
  EXISTING=$(aws ssm describe-document \
    --name "$DOC_NAME" \
    --region "$SOURCE_REGION" \
    --query 'Document.Status' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTING" = "NOT_FOUND" ]; then
    # Create new document
    echo "     Action: Creating new document..."
    aws ssm create-document \
      --name "$DOC_NAME" \
      --document-type "Automation" \
      --document-format "YAML" \
      --content "file://$DOC_FILE" \
      --region "$SOURCE_REGION" \
      --tags "Key=Project,Value=DRSAutomation" "Key=ManagedBy,Value=drs-agent-lifecycle-automation" \
      --output text --query 'DocumentDescription.Status'
    echo "     ✅ Created successfully"
  else
    # Update existing document (create new version and set as default)
    echo "     Action: Updating existing document (current status: $EXISTING)..."
    NEW_VERSION=$(aws ssm update-document \
      --name "$DOC_NAME" \
      --document-format "YAML" \
      --content "file://$DOC_FILE" \
      --document-version '$LATEST' \
      --region "$SOURCE_REGION" \
      --query 'DocumentDescription.DocumentVersion' \
      --output text 2>/dev/null || echo "SAME")

    if [ "$NEW_VERSION" = "SAME" ]; then
      echo "     ℹ️  No changes detected (document is up to date)"
    else
      # Set the new version as default
      aws ssm update-document-default-version \
        --name "$DOC_NAME" \
        --document-version "$NEW_VERSION" \
        --region "$SOURCE_REGION" \
        --output text > /dev/null
      echo "     ✅ Updated to version $NEW_VERSION (set as default)"
    fi
  fi
  echo ""
done

echo "✅ All SSM documents registered successfully"
