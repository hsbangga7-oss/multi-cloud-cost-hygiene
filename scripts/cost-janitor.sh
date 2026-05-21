#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
AWS_ENDPOINT="${AWS_ENDPOINT_URL:-http://localhost:4566}"
DRY_RUN="${DRY_RUN:-true}"   # default safe: never delete without explicit opt-in
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

aws_cmd() {
  aws --endpoint-url "$AWS_ENDPOINT" --region "$REGION" "$@"
}

is_protected() {
  local resource_id="$1" resource_type="$2"
  local protected
  protected=$(aws_cmd resourcegroupstaggingapi get-resources \
    --resource-type-filters "$resource_type" \
    --tag-filters Key=Protected,Values=true \
    --query "ResourceTagMappingList[?ResourceARN contains '$resource_id'] | length(@)" \
    --output text 2>/dev/null || echo "0")
  [[ "$protected" -gt 0 ]]
}

# ── EBS: Unattached Volumes ───────────────────────────────────────────────────
cleanup_unattached_ebs() {
  log "Scanning for unattached EBS volumes..."

  local volumes
  volumes=$(aws_cmd ec2 describe-volumes \
    --filters Name=status,Values=available \
    --query 'Volumes[*].{ID:VolumeId,Size:Size,Tags:Tags}' \
    --output json)

  local count
  count=$(echo "$volumes" | jq 'length')
  log "Found $count unattached volume(s)"

  echo "$volumes" | jq -c '.[]' | while read -r vol; do
    local vol_id size
    vol_id=$(echo "$vol" | jq -r '.ID')
    size=$(echo "$vol"   | jq -r '.Size')

    # Skip protected volumes
    local protected
    protected=$(echo "$vol" | jq -r '.Tags // [] | map(select(.Key=="Protected")) | .[0].Value // "false"')
    if [[ "$protected" == "true" ]]; then
      log "  SKIP $vol_id (Protected=true)"
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log "  DRY-RUN: would delete EBS $vol_id (${size}GB)"
    else
      warn "  DELETING EBS $vol_id (${size}GB)"
      aws_cmd ec2 delete-volume --volume-id "$vol_id"
      log "  Deleted $vol_id"
    fi
  done
}

# ── EC2: Stopped Instance Report (report only, never delete) ─────────────────
report_stopped_ec2() {
  log "Scanning for stopped EC2 instances..."

  aws_cmd ec2 describe-instances \
    --filters Name=instance-state-name,Values=stopped \
    --query 'Reservations[*].Instances[*].{ID:InstanceId,Type:InstanceType,Tags:Tags}' \
    --output json \
  | jq -r '.[][] | "  STOPPED: \(.ID) (\(.Type)) name=\(.Tags // [] | map(select(.Key=="Name")) | .[0].Value // "untagged")"'
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  log "=== Cost Janitor starting (DRY_RUN=$DRY_RUN) ==="
  cleanup_unattached_ebs
  report_stopped_ec2
  log "=== Done ==="
}

main "$@"