#!/usr/bin/env bash
# =============================================================================
# DRS Agent Lifecycle Automation - Initialize Parameter Store
# =============================================================================
# Creates the SSM Parameter Store entry used for DR-event stand-down control.
# Idempotent: creates if not exists, does not overwrite if already set.
#
# Usage:
#   chmod +x scripts/init-parameters.sh
#   ./scripts/init-parameters.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_DIR/config.yaml"

# Read config or use defaults
if command -v yq &> /dev/null && [ -f "$CONFIG_FILE" ]; then
  SOURCE_REGION=$(yq '.source_region' "$CONFIG_FILE")
    STAND_DOWN_PARAM=$(yq '.stand_down_parameter' "$CONFIG_FILE")
    else
      SOURCE_REGION="${SOURCE_REGION:-us-west-1}"
        STAND_DOWN_PARAM="${STAND_DOWN_PARAM:-/drs/control/event-in-progress}"
        fi

        echo "Initializing Parameter Store in $SOURCE_REGION..."
        echo ""

        # ---------------------------------------------------------------------------
        # Stand-down parameter: /drs/control/event-in-progress
        # Default value: "false" (automation is active)
        # Set to "true" during failover/failback to pause all automation.
        # ---------------------------------------------------------------------------
        echo "  Parameter: $STAND_DOWN_PARAM"

        EXISTING_VALUE=$(aws ssm get-parameter \
          --name "$STAND_DOWN_PARAM" \
            --region "$SOURCE_REGION" \
              --query 'Parameter.Value' \
                --output text 2>/dev/null || echo "NOT_FOUND")

                if [ "$EXISTING_VALUE" = "NOT_FOUND" ]; then
                  aws ssm put-parameter \
                      --name "$STAND_DOWN_PARAM" \
                          --value "false" \
                              --type "String" \
                                  --description "DRS Automation stand-down flag. Set to 'true' during failover/failback to pause all automation." \
                                      --tags "Key=Project,Value=DRSAutomation" "Key=ManagedBy,Value=drs-agent-lifecycle-automation" \
                                          --region "$SOURCE_REGION" \
                                              --output text > /dev/null
                                                echo "  ✅ Created with value: false"
                                                else
                                                  echo "  ℹ️  Already exists with value: $EXISTING_VALUE (not overwriting)"
                                                  fi

                                                  echo ""
                                                  echo "✅ Parameter Store initialization complete"
                                                  echo ""
                                                  echo "Usage:"
                                                  echo "  # Activate stand-down (pause automation during DR event):"
                                                  echo "  aws ssm put-parameter --name $STAND_DOWN_PARAM --value 'true' --type String --overwrite --region $SOURCE_REGION"
                                                  echo ""
                                                  echo "  # Deactivate stand-down (resume normal operations):"
                                                  echo "  aws ssm put-parameter --name $STAND_DOWN_PARAM --value 'false' --type String --overwrite --region $SOURCE_REGION"
                                                  
