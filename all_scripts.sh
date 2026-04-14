#!/bin/bash

# ==============================================================================
# AWS FINOPS AUTOMATION SCRIPT
# Purpose: Cleanup orphaned/stale resources to reduce cloud spend.
# Features: Dry-run mode, Tag-based exclusion, Logging, and Multi-service support.
# ==============================================================================

# --- 1. CONFIGURATION ---
DRY_RUN=true               # Set to 'false' to actually perform deletions
RETENTION_DAYS=30          # Age threshold for snapshots, AMIs, and volumes
PROTECTION_TAG="FinOps_Protected" # Resources with this tag=true will be skipped
LOG_FILE="finops_execution_$(date +%F).log"

# Calculate date for AWS JQ filters
CUTOFF_DATE=$(date -d "-$RETENTION_DAYS days" +'%Y-%m-%dT%H:%M:%S')

log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

log "INFO: Starting FinOps Cleanup (DRY_RUN=$DRY_RUN)"

# --- 2. EC2 INSTANCES (Stopped) ---
# Logic: Find instances stopped for any reason that aren't protected.
log "STEP: Checking for stopped EC2 instances..."
stopped_instances=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=stopped" \
    --query "Reservations[*].Instances[?!(Tags[?Key=='$PROTECTION_TAG' && Value=='true'])].InstanceId" \
    --output text)

if [ -n "$stopped_instances" ]; then
    for id in $stopped_instances; do
        if [ "$DRY_RUN" = false ]; then
            aws ec2 terminate-instances --instance-ids "$id" > /dev/null
            log "ACTION: Terminated Instance $id"
        else
            log "DRY-RUN: Would terminate Instance $id"
        fi
    done
else
    log "INFO: No stopped instances to clean."
fi

# --- 3. EBS VOLUMES (Available & Old) ---
log "STEP: Checking for orphaned EBS volumes older than $RETENTION_DAYS days..."
vols=$(aws ec2 describe-volumes \
    --filters "Name=status,Values=available" \
    --query "Volumes[?CreateTime<=\`$CUTOFF_DATE\` && !(Tags[?Key=='$PROTECTION_TAG' && Value=='true'])].VolumeId" \
    --output text)

for vol in $vols; do
    if [ "$DRY_RUN" = false ]; then
        aws ec2 delete-volume --volume-id "$vol"
        log "ACTION: Deleted Volume $vol"
    else
        log "DRY-RUN: Would delete Volume $vol"
    fi
done

# --- 4. ELASTIC IPs (Unattached) ---
# Note: Unattached EIPs are a "hidden" hourly cost.
log "STEP: Checking for unattached Elastic IPs..."
eips=$(aws ec2 describe-addresses \
    --query "Addresses[?InstanceId==null].AllocationId" --output text)

for eip in $eips; do
    if [ "$DRY_RUN" = false ]; then
        aws ec2 release-address --allocation-id "$eip"
        log "ACTION: Released EIP $eip"
    else
        log "DRY-RUN: Would release EIP $eip"
    fi
done

# --- 5. SNAPSHOTS & AMIs (Stale) ---
log "STEP: Checking for stale Snapshots and AMIs..."
# Snapshots
snaps=$(aws ec2 describe-snapshots --owner-ids self \
    --query "Snapshots[?StartTime<=\`$CUTOFF_DATE\` && !(Tags[?Key=='$PROTECTION_TAG' && Value=='true'])].SnapshotId" \
    --output text)

for snap in $snaps; do
    if [ "$DRY_RUN" = false ]; then
        aws ec2 delete-snapshot --snapshot-id "$snap"
        log "ACTION: Deleted Snapshot $snap"
    else
        log "DRY-RUN: Would delete Snapshot $snap"
    fi
done

# AMIs
amis=$(aws ec2 describe-images --owners self \
    --query "Images[?CreationDate<=\`$CUTOFF_DATE\` && !(Tags[?Key=='$PROTECTION_TAG' && Value=='true'])].ImageId" \
    --output text)

for ami in $amis; do
    if [ "$DRY_RUN" = false ]; then
        aws ec2 deregister-image --image-id "$ami"
        log "ACTION: Deregistered AMI $ami"
    else
        log "DRY-RUN: Would deregister AMI $ami"
    fi
done

# --- 6. RDS SNAPSHOTS (Manual & Old) ---
log "STEP: Checking for old RDS Snapshots..."
rds_snaps=$(aws rds describe-db-snapshots --snapshot-type manual \
    --query "DBSnapshots[?SnapshotCreateTime<=\`$CUTOFF_DATE\`].DBSnapshotIdentifier" --output text)

for r_snap in $rds_snaps; do
    if [ "$DRY_RUN" = false ]; then
        aws rds delete-db-snapshot --db-snapshot-identifier "$r_snap"
        log "ACTION: Deleted RDS Snapshot $r_snap"
    else
        log "DRY-RUN: Would delete RDS Snapshot $r_snap"
    fi
done

log "SUCCESS: FinOps Cleanup completed."
