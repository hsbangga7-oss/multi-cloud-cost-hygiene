#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=constants.sh
source "$SCRIPT_DIR/constants.sh"

# ── Constants ─────────────────────────────────────────────────────────────────
STOPPED_EC2_THRESHOLD_DAYS="${STOPPED_DAYS:-14}"

# ── Config ────────────────────────────────────────────────────────────────────
AWS_ENDPOINT="${AWS_ENDPOINT_URL:-http://localhost:4566}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
# Report paths
REPORT_FILE="${REPORT_FILE:-$SCRIPT_DIR/../samples/report.example.json}"
SUMMARY_FILE="${SUMMARY_FILE:-$SCRIPT_DIR/../samples/report.example.md}"
DRY_RUN=true
DELETE=false
REQUIRED_TAGS=("Project" "Environment" "Owner" "ManagedBy")

#  Temp files for findings (fixes subshell scope bug)
FINDINGS_FILE=$(mktemp)
WASTE_FILE=$(mktemp)
echo "[]"   > "$FINDINGS_FILE"
echo "0"    > "$WASTE_FILE"

cleanup() { rm -f "$FINDINGS_FILE" "$WASTE_FILE"; }
trap cleanup EXIT

#  Helpers
log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

aws_cmd() {
  aws --endpoint-url "$AWS_ENDPOINT" --region "$REGION" "$@"
}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

age_days() {
  local created_at="$1"
  local created_ts now_ts
  created_ts=$(date -d "$created_at" +%s 2>/dev/null || echo "0")
  now_ts=$(date +%s)
  echo $(( (now_ts - created_ts) / 86400 ))
}

is_protected() {
  local tags_json="$1"
  local val
  val=$(echo "$tags_json" | jq -r 'if type == "array" then map(select(.Key=="Protected")) | .[0].Value // "false" else "false" end')
  [[ "$val" == "true" ]]
}

missing_tags() {
  local tags_json="$1"
  local missing=()
  for tag in "${REQUIRED_TAGS[@]}"; do
    local val
    val=$(echo "$tags_json" | jq -r --arg t "$tag" 'if type == "array" then map(select(.Key==$t)) | .[0].Value // "null" else "null" end')
    if [[ "$val" == "null" ]]; then
      missing+=("$tag")
    fi
  done
  echo "${missing[*]:-}"
}

# Parse Args 
usage() {
  echo "Usage: $0 [--dry-run] [--delete]"
  echo "  --dry-run   Scan and report only, no deletions (default)"
  echo "  --delete    Delete orphaned resources (skips Protected=true)"
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true;  DELETE=false ;;
    --delete)  DELETE=true;   DRY_RUN=false ;;
    --help)    usage ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

#  Findings accumulator 
add_finding() {
  local resource_id="$1"
  local resource_type="$2"
  local reason="$3"
  local age="$4"
  local cost="$5"
  local tags="$6"
  local suggested_action="$7"
  local safe_to_delete="$8"

  local finding
  finding=$(jq -n \
    --arg rid "$resource_id" \
    --arg rt "$resource_type" \
    --arg r "$reason" \
    --argjson age "$age" \
    --argjson cost "$cost" \
    --argjson tags "$tags" \
    --arg sa "$suggested_action" \
    --argjson std "$safe_to_delete" \
    '{
      resource_id: $rid,
      resource_type: $rt,
      reason: $r,
      age_days: $age,
      estimated_monthly_cost_usd: $cost,
      tags: $tags,
      suggested_action: $sa,
      safe_to_auto_delete: $std
    }')

  local current waste new_waste
  current=$(cat "$FINDINGS_FILE")
  echo "$current" | jq --argjson f "$finding" '. + [$f]' > "$FINDINGS_FILE"

  waste=$(cat "$WASTE_FILE")
  new_waste=$(awk "BEGIN {printf \"%.2f\", $waste + $cost}")
  echo "$new_waste" > "$WASTE_FILE"
}

# Check 1: Unattached EBS Volumes 
scan_ebs() {
  log "Scanning for unattached EBS volumes..."

  local volumes
  volumes=$(aws_cmd ec2 describe-volumes \
    --filters Name=status,Values=available \
    --query 'Volumes[*].{ID:VolumeId,Size:Size,Tags:Tags,CreateTime:CreateTime}' \
    --output json)

  local count
  count=$(echo "$volumes" | jq 'length')
  log "Found $count unattached EBS volume(s)"

  local i=0
  while [[ $i -lt $count ]]; do
    local vol vol_id size tags created age cost protected tag_obj
    vol=$(echo "$volumes" | jq -c ".[$i]")
    vol_id=$(echo "$vol"  | jq -r '.ID')
    size=$(echo "$vol"    | jq -r '.Size')
    tags=$(echo "$vol"    | jq -c '.Tags // []')
    created=$(echo "$vol" | jq -r '.CreateTime // "2024-01-01T00:00:00Z"')
    age=$(age_days "$created")
    cost=$(awk "BEGIN {printf \"%.2f\", $size * $EBS_COST_PER_GB_MONTH}")
    protected=$(is_protected "$tags" && echo true || echo false)

    tag_obj=$(echo "$tags" | jq '{
      Project:     (map(select(.Key=="Project"))     | .[0].Value // null),
      Environment: (map(select(.Key=="Environment")) | .[0].Value // null),
      Owner:       (map(select(.Key=="Owner"))       | .[0].Value // null)
    }')

    add_finding "$vol_id" "ebs_volume" "unattached" "$age" "$cost" "$tag_obj" "delete" "false"

    if [[ "$DELETE" == "true" ]]; then
      if [[ "$protected" == "true" ]]; then
        log "  SKIP $vol_id (Protected=true)"
      else
        warn "  DELETING $vol_id"
        aws_cmd ec2 delete-volume --volume-id "$vol_id"
        log "  Deleted $vol_id"
      fi
    else
      log "  DRY-RUN: would delete EBS $vol_id (${size}GB, ~\$$cost/month)"
    fi
    (( i++ )) || true
  done
}

# Check 2: Stopped EC2 > N days
scan_stopped_ec2() {
  log "Scanning for EC2 instances stopped > ${STOPPED_EC2_THRESHOLD_DAYS} days..."

  local instances
  instances=$(aws_cmd ec2 describe-instances \
    --filters Name=instance-state-name,Values=stopped \
    --query 'Reservations[*].Instances[*].{ID:InstanceId,Type:InstanceType,Tags:Tags,LaunchTime:LaunchTime}' \
    --output json)

  local flat
  flat=$(echo "$instances" | jq -c '[.[][]]')
  local count
  count=$(echo "$flat" | jq 'length')
  log "Found $count stopped instance(s)"

  local i=0
  while [[ $i -lt $count ]]; do
    local inst inst_id tags launched age tag_obj
    inst=$(echo "$flat"       | jq -c ".[$i]")
    inst_id=$(echo "$inst"    | jq -r '.ID')
    tags=$(echo "$inst"       | jq -c '.Tags // []')
    launched=$(echo "$inst"   | jq -r '.LaunchTime // "2024-01-01T00:00:00Z"')
    age=$(age_days "$launched")

    if (( age >= STOPPED_EC2_THRESHOLD_DAYS )); then
      tag_obj=$(echo "$tags" | jq '{
        Project:     (map(select(.Key=="Project"))     | .[0].Value // null),
        Environment: (map(select(.Key=="Environment")) | .[0].Value // null),
        Owner:       (map(select(.Key=="Owner"))       | .[0].Value // null)
      }')
      add_finding "$inst_id" "ec2_instance" "stopped_over_${STOPPED_EC2_THRESHOLD_DAYS}_days" "$age" "0" "$tag_obj" "review_and_terminate" "false"
      log "  STOPPED: $inst_id age=${age}d"
    fi
    (( i++ )) || true
  done
}

# Check 3: Unused Elastic IPs 
scan_elastic_ips() {
  log "Scanning for unused Elastic IPs..."

  local eips
  eips=$(aws_cmd ec2 describe-addresses \
    --query 'Addresses[?AssociationId==null].{IP:PublicIp,AllocId:AllocationId,Tags:Tags}' \
    --output json)

  local count
  count=$(echo "$eips" | jq 'length')
  log "Found $count unused Elastic IP(s)"

  local i=0
  while [[ $i -lt $count ]]; do
    local eip ip alloc_id tags protected tag_obj
    eip=$(echo "$eips"     | jq -c ".[$i]")
    ip=$(echo "$eip"       | jq -r '.IP')
    alloc_id=$(echo "$eip" | jq -r '.AllocId')
    tags=$(echo "$eip"     | jq -c '.Tags // []')
    protected=$(is_protected "$tags" && echo true || echo false)

    tag_obj=$(echo "$tags" | jq '{
      Project:     (map(select(.Key=="Project"))     | .[0].Value // null),
      Environment: (map(select(.Key=="Environment")) | .[0].Value // null),
      Owner:       (map(select(.Key=="Owner"))       | .[0].Value // null)
    }')

    add_finding "$ip" "elastic_ip" "not_associated" "0" "$EIP_COST_PER_MONTH" "$tag_obj" "release" "true"

    if [[ "$DELETE" == "true" ]]; then
      if [[ "$protected" == "true" ]]; then
        log "  SKIP $ip (Protected=true)"
      else
        warn "  RELEASING EIP $ip ($alloc_id)"
        aws_cmd ec2 release-address --allocation-id "$alloc_id"
        log "  Released $ip"
      fi
    else
      log "  DRY-RUN: would release EIP $ip (~\$$EIP_COST_PER_MONTH/month)"
    fi
    (( i++ )) || true
  done
}

# Check 4: Missing Required Tags 
scan_missing_tags() {
  log "Scanning for resources with missing required tags..."

  local instances
  instances=$(aws_cmd ec2 describe-instances \
    --query 'Reservations[*].Instances[*].{ID:InstanceId,Tags:Tags}' \
    --output json)

  local flat
  flat=$(echo "$instances" | jq -c '[.[][]]')
  local count
  count=$(echo "$flat" | jq 'length')

  local i=0
  while [[ $i -lt $count ]]; do
    local inst inst_id tags missing tag_obj
    inst=$(echo "$flat"    | jq -c ".[$i]")
    inst_id=$(echo "$inst" | jq -r '.ID')
    tags=$(echo "$inst"    | jq -c '.Tags // []')
    missing=$(missing_tags "$tags")

    if [[ -n "$missing" ]]; then
      tag_obj=$(echo "$tags" | jq '{
        Project:     (map(select(.Key=="Project"))     | .[0].Value // null),
        Environment: (map(select(.Key=="Environment")) | .[0].Value // null),
        Owner:       (map(select(.Key=="Owner"))       | .[0].Value // null)
      }')
      add_finding "$inst_id" "ec2_instance" "missing_tags:${missing// /,}" "0" "0" "$tag_obj" "tag_or_review" "false"
      log "  MISSING TAGS: $inst_id (missing: $missing)"
    fi
    (( i++ )) || true
  done
}

# Write report.json 
write_report() {
  local total_orphans waste findings account_id
  findings=$(cat "$FINDINGS_FILE")
  total_orphans=$(echo "$findings" | jq 'length')
  waste=$(cat "$WASTE_FILE")
  account_id=$(aws_cmd sts get-caller-identity --query Account --output text 2>/dev/null || echo "000000000000")

  jq -n \
    --arg ts "$(now_iso)" \
    --arg acct "$account_id" \
    --arg region "$REGION" \
    --argjson total "$total_orphans" \
    --argjson waste "$waste" \
    --argjson findings "$findings" \
    '{
      scan_timestamp: $ts,
      account_id: $acct,
      region: $region,
      summary: {
        total_orphans: $total,
        estimated_monthly_waste_usd: $waste
      },
      findings: $findings
    }' > "$REPORT_FILE"

  log "Report written to $REPORT_FILE"
}

# Write report.md
write_markdown() {
  local findings total_orphans waste
  findings=$(cat "$FINDINGS_FILE")
  total_orphans=$(echo "$findings" | jq 'length')
  waste=$(cat "$WASTE_FILE")

  {
    echo "# Cost Janitor Report"
    echo ""
    echo "**Scan Time:** $(now_iso)"
    echo "**Region:** $REGION"
    echo "**Mode:** $([ "$DELETE" == "true" ] && echo 'DELETE' || echo 'DRY-RUN')"
    echo ""
    echo "## Summary"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Total Orphans | $total_orphans |"
    echo "| Estimated Monthly Waste | \$$waste |"
    echo ""
    echo "## Findings"
    echo ""
    echo "| Resource ID | Type | Reason | Age (days) | Est. Cost/month |"
    echo "|-------------|------|--------|------------|-----------------|"
    echo "$findings" | jq -r '.[] | "| \(.resource_id) | \(.resource_type) | \(.reason) | \(.age_days) | $\(.estimated_monthly_cost_usd) |"'
    echo ""
    echo "> Generated by cost-janitor"
  } > "$SUMMARY_FILE"

  log "Markdown summary written to $SUMMARY_FILE"
}

# Main 
main() {
  log "========================================"
  log "  Cost Janitor"
  log "  Mode:     $([ "$DELETE" == "true" ] && echo 'DELETE' || echo 'DRY-RUN')"
  log "  Endpoint: $AWS_ENDPOINT"
  log "  Region:   $REGION"
  log "========================================"

  scan_ebs
  scan_stopped_ec2
  scan_elastic_ips
  scan_missing_tags

  write_report
  write_markdown

  local total_orphans
  total_orphans=$(cat "$FINDINGS_FILE" | jq 'length')

  log "========================================"
  log "  Total orphans found: $total_orphans"
  log "  Estimated waste: \$$(cat "$WASTE_FILE")/month"
  log "========================================"

  if [[ "$DRY_RUN" == "true" && "$total_orphans" -gt 0 ]]; then
    warn "Orphans found in dry-run mode — exiting with code 1"
    exit 1
  fi
}

main "$@"