START_DATE="2025-01-01"
END_DATE="2025-06-01"
REGION="ap-southeast-2"

CACHE_DIR="./snapshot_audit_cache"
CACHE_PREFIX="${CACHE_DIR}/snapshot_audit_${START_DATE}_to_${END_DATE}_${REGION}"

mkdir -p "$CACHE_DIR"

# CloudTrail - CreateSnapshot events
aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=CreateSnapshot \
    --region "$REGION" \
    --start-time "$START_DATE" \
    --end-time "$END_DATE" \
    --output json > "${CACHE_PREFIX}_create_events.json"

# CloudTrail - DeleteSnapshot events
aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteSnapshot \
    --region "$REGION" \
    --start-time "$START_DATE" \
    --end-time "$END_DATE" \
    --output json > "${CACHE_PREFIX}_delete_events.json"

# EC2 - All volumes with instance attachments
aws ec2 describe-volumes \
    --region "$REGION" \
    --query 'Volumes[].{v:VolumeId,i:Attachments[0].InstanceId}' \
    --output json > "${CACHE_PREFIX}_volumes.json"

# EC2 - All instances with names
aws ec2 describe-instances \
    --region "$REGION" \
    --query 'Reservations[].Instances[].{i:InstanceId,n:Tags[?Key==`Name`].Value | [0]}' \
    --output json > "${CACHE_PREFIX}_instances.json"
