# Automate the Full AWS DRS Agent Lifecycle: Install, Heal, Offboard

This sample demonstrates how to automate the full [AWS Elastic Disaster Recovery (AWS DRS)](https://aws.amazon.com/disaster-recovery/) agent lifecycle — install, heal, and offboard — using AWS Systems Manager Automation, State Manager, and Amazon EventBridge.

The solution provides tag-driven, Lambda-free fleet management across Linux and Windows instances. Tag an EC2 instance with `DR=yes` to onboard it; change the tag to `DR=no` (or delete it) to offboard. Stalled replication is automatically healed within minutes to protect your RPO.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  SOURCE REGION (e.g., us-west-1)                                        │
│                                                                         │
│  ┌──────────────┐   tag:DR=yes    ┌─────────────────────┐              │
│  │ EC2 Instance │ ───────────────► │ State Manager       │              │
│  │              │   rate(30 min)   │ → DRS-Agent-Onboard │              │
│  └──────────────┘                  └─────────────────────┘              │
│         │                                                               │
│         │ Tag Change (DR=no)       ┌─────────────────────┐              │
│         └─────────────────────────►│ EventBridge Rule    │              │
│                                    │ → DRS-Agent-Offboard│              │
│                                    └─────────────────────┘              │
│                                                                         │
│  ┌─────────────────────┐          ┌─────────────────────┐              │
│  │ EventBridge Rule    │◄─────────│ DR Region forwards  │              │
│  │ → DRS-Agent-Heal    │ Stalled  │ STALLED events      │              │
│  └─────────────────────┘          └─────────────────────┘              │
└─────────────────────────────────────────────────────────────────────────┘
                                            ▲
┌─────────────────────────────────────────────────────────────────────────┐
│  DR REGION (e.g., us-east-2)              │                             │
│                                           │                             │
│  ┌──────────────────────┐   Stalled Event │                             │
│  │ DRS Source Server    │ ────────────────┘                             │
│  │ (Replicating)        │                                               │
│  └──────────────────────┘                                               │
└─────────────────────────────────────────────────────────────────────────┘
```

## Features

- **Tag-driven lifecycle** — `DR=yes` onboards, `DR=no` offboards, no manual steps
- **Self-healing** — Automatically restarts or reinstalls the DRS agent when replication stalls
- **Cross-platform** — Full support for Amazon Linux, RHEL, Ubuntu, SUSE, and Windows Server
- **DR-event stand-down** — Pauses all automation during failover/failback operations
- **Audit trail** — CloudWatch metrics, SNS alerts, and optional S3 JSON audit logs
- **Idempotent** — Safe to re-run; skips healthy instances, handles edge cases gracefully
- **No Lambda required** — Runs entirely on SSM Automation + EventBridge + State Manager

## Prerequisites

- An AWS account with [AWS DRS initialized](https://docs.aws.amazon.com/drs/latest/userguide/getting-started-initializing.html) in the DR region
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) installed and configured
- EC2 instances with the [SSM Agent](https://docs.aws.amazon.com/systems-manager/latest/userguide/ssm-agent.html) installed (Amazon Linux 2/2023 and Windows Server include it by default)
- Sufficient IAM permissions to create roles, SSM documents, EventBridge rules, and CloudFormation stacks
- (Optional) An SNS topic for alert notifications
- (Optional) An S3 bucket for audit log storage

## Repository Structure

```
.
├── README.md                              # This file
├── LICENSE                                # MIT-0 License
├── config.yaml                            # Deployment configuration (edit before deploying)
├── templates/
│   ├── iam-roles.yaml                     # IAM role for automation
│   ├── eventbridge-source.yaml            # EventBridge rules (source region)
│   ├── eventbridge-dr.yaml                # EventBridge rule (DR region)
│   └── state-manager-association.yaml     # State Manager association
├── documents/
│   ├── DRS-Agent-Onboard.yaml             # SSM Automation: install & validate
│   ├── DRS-Agent-Heal.yaml                # SSM Automation: restart/reinstall
│   └── DRS-Agent-Offboard.yaml            # SSM Automation: teardown
├── scripts/
│   ├── deploy.sh                          # Full deployment script
│   ├── register-documents.sh              # Register SSM documents
│   └── init-parameters.sh                 # Initialize Parameter Store
└── NOTICE                                 # Copyright notice
```

## Deployment

### Step 1: Configure

Edit `config.yaml` with your environment values:

```bash
cp config.yaml config.yaml.bak
# Edit config.yaml with your AWS account ID, regions, and preferences
```

### Step 2: Deploy (automated)

Run the full deployment script:

```bash
chmod +x scripts/*.sh
./scripts/deploy.sh
```

Or deploy step by step:

### Step 2a: Deploy IAM Role

```bash
SOURCE_REGION=us-west-1

aws cloudformation deploy \
  --template-file templates/iam-roles.yaml \
  --stack-name drs-automation-iam \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $SOURCE_REGION \
  --parameter-overrides \
    AccountId=123456789012 \
    SourceRegion=$SOURCE_REGION \
    DRRegion=us-east-2
```

### Step 2b: Register SSM Documents

```bash
./scripts/register-documents.sh
```

### Step 2c: Deploy EventBridge Rules

```bash
# Source region rules (tag change + heal receive)
aws cloudformation deploy \
  --template-file templates/eventbridge-source.yaml \
  --stack-name drs-eventbridge-source \
  --region us-west-1 \
  --parameter-overrides \
    AutomationRoleArn=arn:aws:iam::123456789012:role/DRS-Automation-Role \
    TargetRegion=us-east-2

# DR region rule (stalled event forwarding)
aws cloudformation deploy \
  --template-file templates/eventbridge-dr.yaml \
  --stack-name drs-eventbridge-dr \
  --region us-east-2 \
  --parameter-overrides \
    SourceRegion=us-west-1 \
    AccountId=123456789012
```

### Step 2d: Deploy State Manager Association

```bash
aws cloudformation deploy \
  --template-file templates/state-manager-association.yaml \
  --stack-name drs-state-manager \
  --region us-west-1 \
  --parameter-overrides \
    AutomationRoleArn=arn:aws:iam::123456789012:role/DRS-Automation-Role \
    TargetRegion=us-east-2
```

### Step 2e: Initialize Parameter Store

```bash
./scripts/init-parameters.sh
```

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `source_region` | `us-west-1` | Region where your EC2 instances run |
| `dr_region` | `us-east-2` | Region where DRS replicates data |
| `auto_install_enabled` | `false` | `false` = audit-only; `true` = auto-install agent |
| `auto_offboard_enabled` | `true` | `true` = auto-teardown on descope |
| `dr_tag_key` | `DR` | EC2 tag key that controls the lifecycle |
| `dr_protected_value` | `yes` | Tag value that means "protected by DR" |
| `dr_descope_value` | `no` | Tag value that means "remove from DR" |
| `stand_down_parameter` | `/drs/control/event-in-progress` | SSM parameter to pause automation |
| `schedule_rate` | `rate(30 minutes)` | How often State Manager checks for new instances |

## Usage

### Onboard an Instance

Tag the EC2 instance to enroll it in DR protection:

```bash
aws ec2 create-tags \
  --resources i-0123456789abcdef0 \
  --tags Key=DR,Value=yes \
  --region us-west-1
```

State Manager will pick it up within 30 minutes (or on the next scheduled run) and install the DRS agent.

### Offboard an Instance

Change the tag to remove it from DR protection:

```bash
aws ec2 create-tags \
  --resources i-0123456789abcdef0 \
  --tags Key=DR,Value=no \
  --region us-west-1
```

EventBridge fires immediately, triggering the offboard automation which stops replication, deletes the source server, and uninstalls the agent.

### Pause Automation (DR Event Stand-Down)

During a declared failover or failback, pause all automation:

```bash
# Activate stand-down
aws ssm put-parameter \
  --name /drs/control/event-in-progress \
  --value "true" \
  --type String \
  --overwrite \
  --region us-west-1

# Deactivate stand-down (resume normal operations)
aws ssm put-parameter \
  --name /drs/control/event-in-progress \
  --value "false" \
  --type String \
  --overwrite \
  --region us-west-1
```

### Monitor

- **CloudWatch Metrics**: Namespace `DRSAutomation`, metric `Outcome` with dimension `Event` (ONBOARD/HEAL/OFFBOARD)
- **SNS Notifications**: Failures and escalations are published to the configured SNS topic
- **S3 Audit Logs**: JSON records at `s3://<bucket>/drs/<account>/<instance-id>/<event>-<timestamp>.json`

## Cleanup

To remove all deployed resources:

```bash
SOURCE_REGION=us-west-1
DR_REGION=us-east-2

# Delete CloudFormation stacks
aws cloudformation delete-stack --stack-name drs-state-manager --region $SOURCE_REGION
aws cloudformation delete-stack --stack-name drs-eventbridge-source --region $SOURCE_REGION
aws cloudformation delete-stack --stack-name drs-eventbridge-dr --region $DR_REGION
aws cloudformation delete-stack --stack-name drs-automation-iam --region $SOURCE_REGION

# Delete SSM documents
aws ssm delete-document --name DRS-Agent-Onboard --region $SOURCE_REGION
aws ssm delete-document --name DRS-Agent-Heal --region $SOURCE_REGION
aws ssm delete-document --name DRS-Agent-Offboard --region $SOURCE_REGION

# Delete Parameter Store entry
aws ssm delete-parameter --name /drs/control/event-in-progress --region $SOURCE_REGION
```

## Security

- The IAM role follows least-privilege principles with resource-scoped permissions
- All DRS API calls are cross-region only (source → DR region)
- SNS publish is scoped to `drs-*` topic names
- S3 write is scoped to `drs/*` key prefixes
- Parameter Store access is scoped to `/drs/*` paths
- The stand-down gate prevents automation from interfering with active DR operations
- No credentials are stored in the code; the automation uses IAM role assumption

See [CONTRIBUTING](CONTRIBUTING.md) for information on reporting security issues.

## Cost

This automation uses AWS services that incur costs based on usage. There are no upfront fees or minimum commitments. The following table estimates monthly costs for a fleet of 100 EC2 instances in the US East (N. Virginia) Region.

| Service | Usage driver | Estimated monthly cost |
| --- | --- | --- |
| **SSM Automation** | Onboarding: 100 instances × 48 runs/day = 4,800 step executions/day. First 100,000 steps/month free | **$0** (within free tier for ≤100 instances) |
| **SSM Run Command** | One command per automation run. Free tier: 1,500,000 invocations/month | **$0** |
| **State Manager** | One association (tag:DR=yes, 30-min rate). Free | **$0** |
| **EventBridge** | Custom events (tag changes, stalled events). $1.00 per million events | **< $0.01** |
| **SNS** | Notifications on failures and offboarding. First 1,000 emails/month free | **$0** (typical fleets) |
| **S3** | Audit JSON reports (~1 KB each). Storage: $0.023/GB. At 4,800 reports/day ≈ 144 MB/month | **< $0.01** |
| **CloudWatch** | Custom metrics (Outcome per event type). $0.30/metric/month | **~$0.90** (3 metrics) |
| **Parameter Store** | Standard parameters. Free | **$0** |

**Estimated total for 100 instances: < $1/month** for the automation infrastructure itself.

### What this does NOT include

- **DRS replication costs** — hourly per-server charge, replication server EC2 instances, staging EBS volumes. These are DRS service costs, not automation costs. See [AWS DRS pricing](https://aws.amazon.com/disaster-recovery/pricing/).
- **EC2 instance costs** — your source instances are billed independently of this automation.
- **Data transfer** — cross-Region data transfer for replication is billed by DRS, not by this automation. The automation's cross-Region API calls (boto3 to the DR Region) transfer negligible data.

### Scaling notes

- At **1,000 instances**, SSM Automation steps exceed the free tier (~144,000 steps/month). Overage is $0.00025/step, adding approximately **$11/month**.
- At **10,000 instances**, expect approximately **$110/month** for SSM Automation steps. Consider increasing the State Manager schedule interval (e.g., 60 minutes instead of 30) to halve step costs.
- S3 and CloudWatch costs scale linearly but remain negligible at all fleet sizes.



## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
