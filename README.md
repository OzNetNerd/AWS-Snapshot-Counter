# AWS Snapshot Audit

Audit EBS snapshot create/delete activity from CloudTrail. Identifies orphaned snapshots and maps volumes to instances.

## Usage

```bash
./snapshot_audit.sh -s START_DATE -r REGION [-e END_DATE] [-f]
```

**Required:**
- `-s, --start` - Start date (YYYY-MM-DD)
- `-r, --region` - AWS region

**Optional:**
- `-e, --end` - End date (default: now)
- `-f, --filter` - Hide `Client.Invalid*` errors from output and counts
- `-h, --help` - Show help

## Examples

```bash
# Last 30 days in Sydney
./snapshot_audit.sh -s 2025-11-11 -r ap-southeast-2

# Specific date range, filtering out invalid snapshot errors
./snapshot_audit.sh -s 2025-01-01 -e 2025-06-01 -r us-east-1 -f
```

## Output

**Event Log** - Each CreateSnapshot/DeleteSnapshot event with:
- Timestamp, event type, IAM identity
- Snapshot ID, Volume ID, Instance ID, Instance Name
- Result status, CloudTrail Event ID

**Summary** - Includes:
- CreateSnapshot (success/failed)
- DeleteSnapshot (success/failed)
- Sum verification, unique instances, orphaned snapshot count

**Orphaned Snapshots** - Snapshots created within the audit period with no corresponding delete event. These may have been deleted after the audit window or may still exist.

## Caching

Results are cached in `./snapshot_audit_cache/` to avoid repeated API calls:
- `*_cloudtrail.json` - CloudTrail events
- `*_volumes.json` - Volume→Instance mappings
- `*_instances.json` - Instance names
- `*_report.txt` - Final report

Cache age is displayed when using cached data. Delete the cache directory to refresh.

## Example Output

```
==============================================
AWS Snapshot Audit
Region: ap-southeast-2
Date Range: 2025-01-01 to now
==============================================

[CACHED] CloudTrail data found: ./snapshot_audit_cache/snapshot_audit_2025-01-01_to_now_ap-southeast-2_cloudtrail.json
[INFO] Total CloudTrail events found: 47

[PROCESSING] Extracting volume IDs from events...
[INFO] Unique volume IDs: 12
[CACHED] ./snapshot_audit_cache/snapshot_audit_2025-01-01_to_now_ap-southeast-2_volumes.json
[INFO] Volumes matched: 12, with instance attached: 9

[INFO] Unique instance IDs: 9
[CACHED] ./snapshot_audit_cache/snapshot_audit_2025-01-01_to_now_ap-southeast-2_instances.json
[INFO] Instances with names: 9

[PROCESSING] Generating report...

=== EVENT LOG ===

#   TIME                 EVENT   IDENTITY              SNAPSHOT                VOLUME                  INSTANCE             NAME                  RESULT                      EVENT_ID
-   ----                 -----   --------              --------                ------                  --------             ----                  ------                      --------
1   2025-01-03 02:14:07  Create  AWSBackup             snap-0a1b2c3d4e5f6a7b8  vol-0123456789abcdef0   i-0a1b2c3d4e5f67890  prod-web-server-01    pending                     abc12345-1234-5678-90ab-cdef12345678
2   2025-01-03 02:14:22  Create  AWSBackup             snap-0b2c3d4e5f6a7b8c9  vol-0234567890abcdef1   i-0b2c3d4e5f678901a  prod-db-primary       pending                     bcd23456-2345-6789-01ab-cdef23456789
3   2025-01-03 02:15:01  Create  AWSBackup             snap-0c3d4e5f6a7b8c9d0  vol-0345678901abcdef2   i-0c3d4e5f6789012ab  prod-api-server       pending                     cde34567-3456-7890-12ab-cdef34567890
4   2025-01-04 09:22:15  Delete  AWSBackup             snap-0a1b2c3d4e5f6a7b8  vol-0123456789abcdef0   i-0a1b2c3d4e5f67890  prod-web-server-01    OK                          def45678-4567-8901-23ab-cdef45678901
5   2025-01-04 09:22:18  Delete  AWSBackup             snap-0b2c3d4e5f6a7b8c9  vol-0234567890abcdef1   i-0b2c3d4e5f678901a  prod-db-primary       OK                          efg56789-5678-9012-34ab-cdef56789012
6   2025-01-05 14:30:00  Create  john.smith            snap-0d4e5f6a7b8c9d0e1  vol-0456789012abcdef3   i-0d4e5f6a7890123bc  staging-app-01        pending                     fgh67890-6789-0123-45ab-cdef67890123
7   2025-01-05 14:35:22  Delete  john.smith            snap-0d4e5f6a7b8c9d0e1  vol-0456789012abcdef3   i-0d4e5f6a7890123bc  staging-app-01        OK                          ghi78901-7890-1234-56ab-cdef78901234
8   2025-01-06 03:00:05  Create  AWSBackup             snap-0e5f6a7b8c9d0e1f2  vol-0567890123abcdef4   i-0e5f6a7b89012345c  prod-worker-01        pending                     hij89012-8901-2345-67ab-cdef89012345
9   2025-01-06 03:00:12  Create  AWSBackup             -                       vol-0678901234abcdef5   -                    -                     Client.InvalidVolume.NotFound  ijk90123-9012-3456-78ab-cdef90123456
10  2025-01-07 08:45:33  Delete  DLMLifecyclePolicy    snap-0f6a7b8c9d0e1f2a3  vol-0789012345abcdef6   i-0f6a7b8c90123456d  prod-cache-01         Client.InvalidSnapshot.NotFound  jkl01234-0123-4567-89ab-cdef01234567
11  2025-01-08 11:20:00  Create  terraform-runner      snap-0a7b8c9d0e1f2a3b4  vol-0890123456abcdef7   i-0a7b8c9d01234567e  dev-test-instance     pending                     klm12345-1234-5678-90ab-cdef12345678

=== SUMMARY ===

Date range: 01/01/25 - 11/12/25 (344 days)
Total events in log:              11
  CreateSnapshot (success):       5
  CreateSnapshot (failed):        1
  DeleteSnapshot (success):       3
  DeleteSnapshot (failed):        1
Unique instances:                 9
Orphaned snapshots:               2

=== ORPHANED SNAPSHOTS ===
(These snapshots were created but not deleted within the audit period)

  snap-0c3d4e5f6a7b8c9d0  created: 2025-01-03T02:15:01Z  volume: vol-0345678901abcdef2  instance: i-0c3d4e5f6789012ab (prod-api-server)
  snap-0a7b8c9d0e1f2a3b4  created: 2025-01-08T11:20:00Z  volume: vol-0890123456abcdef7  instance: i-0a7b8c9d01234567e (dev-test-instance)

==============================================
Output Files:
  CloudTrail cache: ./snapshot_audit_cache/snapshot_audit_2025-01-01_to_now_ap-southeast-2_cloudtrail.json
  Volume cache:     ./snapshot_audit_cache/snapshot_audit_2025-01-01_to_now_ap-southeast-2_volumes.json
  Instance cache:   ./snapshot_audit_cache/snapshot_audit_2025-01-01_to_now_ap-southeast-2_instances.json
  Report:           ./snapshot_audit_cache/snapshot_audit_2025-01-01_to_now_ap-southeast-2_report.txt
==============================================
```

## Notes

- Volume→Instance mappings reflect **current** attachment state; CloudTrail resources (when present) show historical state
- Volumes/instances that no longer exist won't have name mappings
- CloudTrail retains 90 days of management events by default
- Requires AWS CLI with `cloudtrail:LookupEvents`, `ec2:DescribeVolumes`, `ec2:DescribeInstances` permissions
- Works on both Linux (GNU) and macOS (BSD)

# Disclaimer

This is a personal project and is not affiliated with, endorsed by, or supported by my employer. It is provided as-is with no guarantees of accuracy, completeness, or fitness for any purpose. Use at your own risk.
