#!/bin/bash
set -eo pipefail

# =============================================================================
# AWS Snapshot Audit Script
# Tracks CreateSnapshot and DeleteSnapshot events from CloudTrail
# =============================================================================

# === DEFAULTS ===
START_DATE=""
END_DATE=""
REGION=""
CACHE_DIR="./snapshot_audit_cache"

# === HELP ===
show_help() {
    cat << EOF
AWS Snapshot Audit - Track CreateSnapshot/DeleteSnapshot events from CloudTrail

Usage: $(basename "$0") -s START_DATE -r REGION [OPTIONS]

Required:
  -s, --start DATE    Start date (YYYY-MM-DD)
  -r, --region REGION AWS region

Optional:
  -e, --end DATE      End date (default: now)
  -h, --help          Show this help message

Examples:
  $(basename "$0") -s 2025-01-01 -r ap-southeast-2
  $(basename "$0") -s 2025-01-01 -e 2025-06-01 -r us-east-1
EOF
    exit 0
}

# === PARSE ARGS ===
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--start)  START_DATE="$2"; shift 2 ;;
        -e|--end)    END_DATE="$2"; shift 2 ;;
        -r|--region) REGION="$2"; shift 2 ;;
        -h|--help)   show_help ;;
        *)           echo "Unknown option: $1"; show_help ;;
    esac
done

# === VALIDATE REQUIRED ARGS ===
if [[ -z "$START_DATE" ]]; then
    echo "ERROR: Start date is required (-s)"
    show_help
fi
if [[ -z "$REGION" ]]; then
    echo "ERROR: Region is required (-r)"
    show_help
fi

# === SETUP ===
mkdir -p "$CACHE_DIR"

# Build cache filename based on date range
if [[ -n "$END_DATE" ]]; then
    CACHE_PREFIX="${CACHE_DIR}/snapshot_audit_${START_DATE}_to_${END_DATE}_${REGION}"
else
    CACHE_PREFIX="${CACHE_DIR}/snapshot_audit_${START_DATE}_to_now_${REGION}"
fi

CLOUDTRAIL_CACHE="${CACHE_PREFIX}_cloudtrail.json"
VOLUME_CACHE="${CACHE_PREFIX}_volumes.json"
INSTANCE_CACHE="${CACHE_PREFIX}_instances.json"
OUTPUT_FILE="${CACHE_PREFIX}_report.txt"

echo "=============================================="
echo "AWS Snapshot Audit"
echo "Region: $REGION"
echo "Date Range: $START_DATE to ${END_DATE:-now}"
echo "=============================================="
echo ""

# =============================================================================
# STEP 1: Fetch CloudTrail Events (with caching)
# =============================================================================
if [[ -f "$CLOUDTRAIL_CACHE" ]]; then
    echo "[CACHED] CloudTrail data found: $CLOUDTRAIL_CACHE"
    CLOUDTRAIL_DATA=$(cat "$CLOUDTRAIL_CACHE")
else
    echo "[FETCHING] CloudTrail CreateSnapshot events..."
    
    # Build date arguments
    DATE_ARGS="--start-time $START_DATE"
    [[ -n "$END_DATE" ]] && DATE_ARGS="$DATE_ARGS --end-time $END_DATE"
    
    CREATE_EVENTS=$(aws cloudtrail lookup-events \
        --lookup-attributes AttributeKey=EventName,AttributeValue=CreateSnapshot \
        --region "$REGION" \
        $DATE_ARGS \
        --output json 2>&1) || { echo "ERROR fetching CreateSnapshot events: $CREATE_EVENTS"; exit 1; }
    
    echo "[FETCHING] CloudTrail DeleteSnapshot events..."
    DELETE_EVENTS=$(aws cloudtrail lookup-events \
        --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteSnapshot \
        --region "$REGION" \
        $DATE_ARGS \
        --output json 2>&1) || { echo "ERROR fetching DeleteSnapshot events: $DELETE_EVENTS"; exit 1; }
    
    # Combine into array of two result sets
    CLOUDTRAIL_DATA=$(echo "$CREATE_EVENTS"$'\n'"$DELETE_EVENTS" | jq -s '.')
    
    echo "$CLOUDTRAIL_DATA" > "$CLOUDTRAIL_CACHE"
    echo "[SAVED] CloudTrail data cached to: $CLOUDTRAIL_CACHE"
fi

# Count events for progress
TOTAL_EVENTS=$(echo "$CLOUDTRAIL_DATA" | jq '[.[].Events | length] | add // 0')
echo "[INFO] Total CloudTrail events found: $TOTAL_EVENTS"
echo ""

# =============================================================================
# STEP 2: Get Volume->Instance mapping
# =============================================================================
echo "[PROCESSING] Extracting volume IDs from events..."

VOLUME_IDS=$(echo "$CLOUDTRAIL_DATA" | jq -r '
    [.[].Events[]?.CloudTrailEvent | fromjson | 
     .requestParameters.volumeId // empty] | 
    unique | .[]' | grep . || true)

VOLUME_COUNT=0
[[ -n "$VOLUME_IDS" ]] && VOLUME_COUNT=$(echo "$VOLUME_IDS" | wc -l | tr -d ' ')
echo "[INFO] Unique volume IDs: $VOLUME_COUNT"

if [[ -f "$VOLUME_CACHE" ]]; then
    echo "[CACHED] $VOLUME_CACHE"
    VOLUME_MAP=$(cat "$VOLUME_CACHE")
elif [[ $VOLUME_COUNT -gt 0 ]]; then
    echo "[FETCHING] All volumes in region, filtering to matches..."
    # Get ALL volumes, then filter to ones in our list
    ALL_VOLUMES=$(aws ec2 describe-volumes \
        --region "$REGION" \
        --query 'Volumes[].{v:VolumeId,i:Attachments[0].InstanceId}' \
        --output json 2>/dev/null || echo "[]")
    
    # Filter to only volumes in our CloudTrail events
    VOLUME_MAP=$(echo "$ALL_VOLUMES" | jq --argjson ids "$(echo "$VOLUME_IDS" | jq -R . | jq -s .)" '
        [.[] | select(.v as $v | $ids | index($v))]')
    echo "$VOLUME_MAP" > "$VOLUME_CACHE"
else
    VOLUME_MAP="[]"
    echo "$VOLUME_MAP" > "$VOLUME_CACHE"
fi

MAPPED_VOLUMES=$(echo "$VOLUME_MAP" | jq '[.[] | select(.i != null)] | length')
echo "[INFO] Volumes matched: $(echo "$VOLUME_MAP" | jq 'length'), with instance attached: $MAPPED_VOLUMES"
echo ""

# =============================================================================
# STEP 3: Get Instance Names
# =============================================================================
INSTANCE_IDS=$(echo "$VOLUME_MAP" | jq -r '[.[] | select(.i != null) | .i] | unique | .[]' | grep . || true)

INSTANCE_COUNT=0
[[ -n "$INSTANCE_IDS" ]] && INSTANCE_COUNT=$(echo "$INSTANCE_IDS" | wc -l | tr -d ' ')
echo "[INFO] Unique instance IDs: $INSTANCE_COUNT"

if [[ -f "$INSTANCE_CACHE" ]]; then
    echo "[CACHED] $INSTANCE_CACHE"
    INSTANCE_MAP=$(cat "$INSTANCE_CACHE")
elif [[ $INSTANCE_COUNT -gt 0 ]]; then
    echo "[FETCHING] All instances in region, filtering to matches..."
    # Get ALL instances, then filter to ones in our list
    ALL_INSTANCES=$(aws ec2 describe-instances \
        --region "$REGION" \
        --query 'Reservations[].Instances[].{i:InstanceId,n:Tags[?Key==`Name`].Value | [0]}' \
        --output json 2>/dev/null || echo "[]")
    
    # Filter to only instances in our list
    INSTANCE_MAP=$(echo "$ALL_INSTANCES" | jq --argjson ids "$(echo "$INSTANCE_IDS" | jq -R . | jq -s .)" '
        [.[] | select(.i as $i | $ids | index($i))]')
    echo "$INSTANCE_MAP" > "$INSTANCE_CACHE"
else
    INSTANCE_MAP="[]"
    echo "$INSTANCE_MAP" > "$INSTANCE_CACHE"
fi

MAPPED_INSTANCES=$(echo "$INSTANCE_MAP" | jq 'length')
echo "[INFO] Instances with names: $MAPPED_INSTANCES"
echo ""

# =============================================================================
# STEP 4: Process and Generate Report
# =============================================================================
echo "[PROCESSING] Generating report..."
echo ""

# Cross-platform date helper (GNU/Linux and macOS)
parse_date() {
    local input="$1" fmt="$2"
    # Try GNU date first, then macOS
    date -d "$input" +"$fmt" 2>/dev/null || date -j -f "%Y-%m-%d" "$input" +"$fmt" 2>/dev/null || echo "$input"
}

date_to_epoch() {
    local input="$1"
    date -d "$input" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$input" +%s 2>/dev/null
}

# Calculate date range info for summary
START_FORMATTED=$(parse_date "$START_DATE" "%d/%m/%y")
if [[ -n "$END_DATE" ]]; then
    END_FORMATTED=$(parse_date "$END_DATE" "%d/%m/%y")
    DAYS=$(( ($(date_to_epoch "$END_DATE") - $(date_to_epoch "$START_DATE")) / 86400 ))
else
    END_FORMATTED=$(date +"%d/%m/%y")
    DAYS=$(( ($(date +%s) - $(date_to_epoch "$START_DATE")) / 86400 ))
fi
DATE_RANGE_INFO="${START_FORMATTED} - ${END_FORMATTED} (${DAYS} days)"

REPORT=$(echo "$CLOUDTRAIL_DATA" | jq -r --argjson vmap "$VOLUME_MAP" --argjson imap "$INSTANCE_MAP" --arg daterange "$DATE_RANGE_INFO" '
    # Build lookup tables
    # Volume ID -> Instance ID
    ($vmap | map(select(.v != null) | {(.v): (.i // "detached")}) | add // {}) as $vol_to_inst |
    
    # Instance ID -> Instance Name
    ($imap | map(select(.i != null) | {(.i): (.n // "(no name)")}) | add // {}) as $inst_to_name |
    
    # Parse and sort all CloudTrail events
    [.[].Events[]?.CloudTrailEvent | fromjson] | sort_by(.eventTime) as $events |
    
    # Categorize events
    # Creates: successful CreateSnapshot with a snapshotId in response
    [$events[] | select(.eventName == "CreateSnapshot" and .responseElements.snapshotId != null)] as $creates_list |
    
    # Failed creates: CreateSnapshot WITH an error
    [$events[] | select(.eventName == "CreateSnapshot" and .errorCode != null)] as $failed_creates |
    
    # Successful deletes: DeleteSnapshot with snapshotId and NO error
    [$events[] | select(.eventName == "DeleteSnapshot" and .requestParameters.snapshotId != null and (.errorCode == null))] as $deletes_list |
    
    # Failed deletes: DeleteSnapshot WITH an error (usually "already deleted")
    [$events[] | select(.eventName == "DeleteSnapshot" and .errorCode != null)] as $failed_deletes |
    
    # Build indexes for orphan detection
    # Key by snapshot ID for quick lookup
    ($creates_list | map({key: .responseElements.snapshotId, value: .}) | from_entries) as $creates_by_snap |
    ($deletes_list | map(.requestParameters.snapshotId) | unique) as $deleted_snap_ids |
    
    # Find orphans: snapshots that were created but never deleted
    [$creates_by_snap | keys[] | select(. as $id | $deleted_snap_ids | index($id) | not)] as $orphan_ids |
    
    # Counts
    ($creates_list | length) as $create_count |
    ($failed_creates | length) as $failed_create_count |
    ($deletes_list | length) as $delete_count |
    ($failed_deletes | length) as $failed_count |
    ($orphan_ids | length) as $orphan_count |
    
    # Total event count for verification
    ($events | length) as $total_events |
    
    # Output header
    "=== EVENT LOG ===",
    "",
    (["#", "TIME", "EVENT", "IDENTITY", "SNAPSHOT", "VOLUME", "INSTANCE", "NAME", "RESULT", "EVENT_ID"] | @tsv),
    (["-", "----", "-----", "--------", "--------", "------", "--------", "----", "------", "--------"] | @tsv),
    
    # Output each event with row number
    ($events | to_entries | .[] |
        .key as $idx |
        .value | 
        # Look up instance from volume
        (.requestParameters.volumeId // "") as $vol_id |
        ($vol_to_inst[$vol_id] // "-") as $inst_id |
        (if $inst_id == "-" or $inst_id == "detached" then "-" else ($inst_to_name[$inst_id] // "-") end) as $inst_name |
        
        # Determine result/status
        (if .errorCode then 
            .errorCode
         elif .responseElements._return == true then 
            "OK" 
         elif .responseElements.status then 
            .responseElements.status 
         else 
            "OK" 
         end) as $result |
        
        # Determine snapshot ID (response for create, request for delete)
        (if .eventName == "CreateSnapshot" then 
            .responseElements.snapshotId 
         else 
            .requestParameters.snapshotId 
         end // "-") as $snap_id |
        
        # Determine identity (truncate to 20 chars)
        (.userIdentity.sessionContext.sessionIssuer.userName // 
         .userIdentity.userName // 
         .userIdentity.principalId // 
         "-") as $identity |
        ($identity | if length > 20 then .[:17] + "..." else . end) as $identity_short |
        
        # Truncate instance name
        ($inst_name | if length > 20 then .[:17] + "..." else . end) as $name_short |
        
        # Shorten event name
        (if .eventName == "CreateSnapshot" then "Create" else "Delete" end) as $event_short |
        
        # Compact time: YYYY-MM-DD HH:MM:SS
        (.eventTime | split("T") | .[0] + " " + (.[1] | split(".")[0])) as $time_compact |
        
        # Event ID for CloudTrail lookup
        .eventID as $event_id |
        
        [
            ($idx + 1),
            $time_compact,
            $event_short,
            $identity_short,
            $snap_id,
            ($vol_id | if . == "" then "-" else . end),
            $inst_id,
            $name_short,
            $result,
            $event_id
        ] | @tsv
    ),
    
    "",
    "=== SUMMARY ===",
    "",
    "Date range: \($daterange)",
    "Total events in log:              \($total_events)",
    "  - CreateSnapshot (success):     \($create_count)",
    "  - CreateSnapshot (failed):      \($failed_create_count)",
    "  - DeleteSnapshot (success):     \($delete_count)",
    "  - DeleteSnapshot (failed):      \($failed_count)",
    "Unique instances:                 \($imap | length)",
    "Orphaned snapshots:               \($orphan_count)",
    "",
    
    # Orphan details if any
    if $orphan_count > 0 then
        "=== ORPHANED SNAPSHOTS ===",
        "(These snapshots were created but not deleted within the audit period)",
        "",
        ($orphan_ids[] | . as $snap_id | $creates_by_snap[$snap_id] |
            (.requestParameters.volumeId // "-") as $vol_id |
            ($vol_to_inst[$vol_id] // "-") as $inst_id |
            (if $inst_id == "-" or $inst_id == "detached" then "-" else ($inst_to_name[$inst_id] // "-") end) as $inst_name |
            "  \($snap_id)  created: \(.eventTime)  volume: \($vol_id)  instance: \($inst_id) (\($inst_name))"
        ),
        ""
    else
        "=== NO ORPHANED SNAPSHOTS ===",
        "(All snapshots created in this period were also deleted)",
        ""
    end
')

# Display and save report
echo "$REPORT" | column -t -s$'\t'
echo "$REPORT" | column -t -s$'\t' > "$OUTPUT_FILE"

echo ""
echo "=============================================="
echo "Output Files:"
echo "  CloudTrail cache: $CLOUDTRAIL_CACHE"
echo "  Volume cache:     $VOLUME_CACHE"
echo "  Instance cache:   $INSTANCE_CACHE"
echo "  Report:           $OUTPUT_FILE"
echo "=============================================="