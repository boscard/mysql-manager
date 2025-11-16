#!/usr/bin/env bash

set -euo pipefail

# Function to execute MySQL queries via mysql
run_mysql_query() {
    local query="$1"
    mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" --password="${DB_PASSWORD}" --ssl-verify-server-cert=false -e "$query"
}

# Function to create a database dump with CREATE DATABASE statement
create_database_dump() {
    local output_file="$1"
    mysqldump -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" --password="${DB_PASSWORD}" \
        --databases "${DB_NAME}" \
        --single-transaction \
        --routines \
        --triggers \
        --ssl-verify-server-cert=false \
        > "${output_file}"
}

# Function to restore a database dump
restore_database_dump() {
    local dump_file="$1"
    mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" --password="${DB_PASSWORD}" --ssl-verify-server-cert=false < "${dump_file}"
}

# Function to execute s3cmd commands with common parameters
run_s3cmd() {
    s3cmd --config=/s3cmd.conf \
        --ca-certs="${S3_CA_BUNDLE}" \
        --access_key="${ACCESS_KEY}" \
        --secret_key="${SECRET_KEY}" \
        --host="${HOST_BASE}" \
        --host-bucket="${HOST_BUCKET}" \
        "$@"
}

# Function to generate timestamp of current date minus duration
# Parameter can be raw seconds (e.g., "3600") or with unit suffix:
# - "d" for days (e.g., "1d" = 1 day)
# - "h" for hours (e.g., "2h" = 2 hours)
# - "m" for minutes (e.g., "30m" = 30 minutes)
# - "s" for seconds (e.g., "60s" = 60 seconds)
generate_timestamp_minus_duration() {
    local input="$1"
    local seconds=0
    
    # Check if input ends with a letter (unit)
    if [[ "$input" =~ ^([0-9]+)([dhms])$ ]]; then
        local number="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        
        case "$unit" in
            d) seconds=$((number * 86400)) ;;  # days
            h) seconds=$((number * 3600)) ;;  # hours
            m) seconds=$((number * 60)) ;;     # minutes
            s) seconds=$number ;;              # seconds
        esac
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        # Raw seconds, no unit
        seconds=$input
    else
        echo "Invalid duration format: $input" >&2
        return 1
    fi
    
    # Calculate timestamp: current timestamp minus seconds
    # Output just the Unix timestamp (seconds)
    echo $(($(date +%s) - seconds))
}

# Function to convert duration string to seconds
# Parameter can be raw seconds (e.g., "3600") or with unit suffix:
# - "d" for days, "h" for hours, "m" for minutes, "s" for seconds
duration_to_seconds() {
    local input="$1"
    local seconds=0
    
    # Check if input ends with a letter (unit)
    if [[ "$input" =~ ^([0-9]+)([dhms])$ ]]; then
        local number="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        
        case "$unit" in
            d) seconds=$((number * 86400)) ;;  # days
            h) seconds=$((number * 3600)) ;;  # hours
            m) seconds=$((number * 60)) ;;     # minutes
            s) seconds=$number ;;              # seconds
        esac
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        # Raw seconds, no unit
        seconds=$input
    else
        echo "Invalid duration format: $input" >&2
        return 1
    fi
    
    echo $seconds
}

# Function to wait for required services to be ready
wait_for_services() {
    # Wait for MySQL
    echo "Waiting for MySQL to be ready..."
    until run_mysql_query "SELECT 1" >/dev/null
    do
        echo "Waiting for MySQL..."
        sleep 2
    done
    echo "MySQL is ready!"
    
    # Wait for S3 storage
    echo "Waiting for S3 storage to be accessible..."
    until run_s3cmd ls "s3://${S3_BUCKET}" >/dev/null
    do
        echo "Waiting for S3 bucket..."
        sleep 2
    done
    echo "S3 storage is accessible!"
}

# Function to initialize lastBackupTime table
# Parameter: "now" to set current timestamp, "zero" to set Unix epoch (0)
initialize_last_backup_time() {
    local mode="${1:-zero}"
    local timestamp_value
    
    case "$mode" in
        now)
            timestamp_value="NOW()"
            echo "Initializing lastBackupTime with current timestamp."
            ;;
        zero)
            timestamp_value="'1970-01-01 00:00:01'"
            echo "Initializing lastBackupTime with 0."
            ;;
        *)
            return 1
            ;;
    esac
    
    run_mysql_query "CREATE TABLE IF NOT EXISTS ${DB_MANAGER}.lastBackupTime (timestamp TIMESTAMP)"
    run_mysql_query "DELETE FROM ${DB_MANAGER}.lastBackupTime"
    run_mysql_query "INSERT INTO ${DB_MANAGER}.lastBackupTime (timestamp) VALUES (${timestamp_value})"
}

# Function to restore database from backup if needed
restore_database() {
    # Check if database exists, create if not
    echo "Checking for ${DB_MANAGER} database..."
    if ! run_mysql_query "SHOW DATABASES LIKE '${DB_MANAGER}'" | grep -q "${DB_MANAGER}"; then
        echo "${DB_MANAGER} database not found. Creating database..."
        run_mysql_query "CREATE DATABASE IF NOT EXISTS ${DB_MANAGER}"
        echo "${DB_MANAGER} database created."
    fi

    # Check if lastBackupTime table exists, create if not
    echo "Checking for lastBackupTime table..."
    if ! run_mysql_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${DB_MANAGER}' AND table_name = 'lastBackupTime'" | grep -q "1"; then
        echo "lastBackupTime table not found. Database appears to be empty. Restoring from backup..."
        
        # Construct path to latest.txt
        latest_txt_path="${S3_BUCKET}/latest.txt"
        latest_txt_file="/tmp/latest.txt"
        
        # Download latest.txt to get the backup filename
        echo "Downloading latest.txt from s3://${latest_txt_path}..."
        if run_s3cmd get "s3://${latest_txt_path}" "${latest_txt_file}"; then
            # Read the backup filename from latest.txt
            if [ -f "${latest_txt_file}" ]; then
                backup_filename=$(cat "${latest_txt_file}")
                rm -f "${latest_txt_file}"
                
                if [ -n "$backup_filename" ]; then
                    echo "Found backup filename in latest.txt: ${backup_filename}"
                    
                    # Construct full path to backup file
                    backup_s3_path="${S3_BUCKET}/${backup_filename}"
                    backup_file="/tmp/db_backup.sql"
                    
                    echo "Downloading backup from s3://${backup_s3_path}..."
                    if run_s3cmd get "s3://${backup_s3_path}" "${backup_file}"; then
                        echo "Backup downloaded successfully. Restoring database..."
                        if restore_database_dump "${backup_file}"; then
                            echo "Database restored successfully from backup."
                            # Clean up temporary backup file
                            rm -f "${backup_file}"
                            
                            # Update lastBackupTime with current timestamp
                            initialize_last_backup_time "now"
                        else
                            echo "Failed to restore database from backup." >&2
                            rm -f "${backup_file}"
                            exit 1
                        fi
                    else
                        echo "No backup file found on S3. Initializing lastBackupTime with 0." >&2
                        initialize_last_backup_time "zero"
                    fi
                else
                    echo "latest.txt is empty or invalid." >&2
                    exit 1
                fi
            else
                echo "Failed to read latest.txt file." >&2
                exit 1
            fi
        else
            echo "No latest.txt found on S3. Initializing lastBackupTime with 0." >&2
            initialize_last_backup_time "zero"
        fi
    fi
}

# Function to check and create backup if needed
backup_database() {
    # Check last backup time
    echo "Checking last backup time..."
    LAST_BACKUP=$(run_mysql_query "SELECT timestamp FROM ${DB_MANAGER}.lastBackupTime LIMIT 1" | tail -n +2 | head -n 1 || echo "")
    if [ -n "$LAST_BACKUP" ]; then
        echo "Last backup time: $LAST_BACKUP"
        
        # Convert MySQL timestamp to Unix timestamp
        LAST_BACKUP_UNIX=$(date -d "$LAST_BACKUP" +%s || echo "0")
        CURRENT_UNIX=$(date +%s)
        ELAPSED_SECONDS=$((CURRENT_UNIX - LAST_BACKUP_UNIX))
        
        # Convert backup interval to seconds
        BACKUP_INTERVAL_SECONDS=$(duration_to_seconds "${DB_BACKUP_INTERVAL:-1h}")
        
        echo "Elapsed time since last backup: ${ELAPSED_SECONDS}s, Interval: ${BACKUP_INTERVAL_SECONDS}s"
        
        # Check if backup is needed
        if [ $ELAPSED_SECONDS -gt $BACKUP_INTERVAL_SECONDS ]; then
            echo "Backup interval exceeded. Creating new backup..."
            
            # Create backup
            backup_filename="db_backup_$(date +%Y%m%d_%H%M%S).sql"
            backup_file="/tmp/${backup_filename}"
            if create_database_dump "${backup_file}"; then
                echo "Backup created successfully. Uploading to S3..."
                
                # Construct S3 paths
                backup_s3_path="${S3_BUCKET}/${backup_filename}"
                latest_txt_path="${S3_BUCKET}/latest.txt"
                latest_txt_file="/tmp/latest.txt"
                
                # Upload backup to S3
                if run_s3cmd put "${backup_file}" "s3://${backup_s3_path}"; then
                    echo "Backup uploaded successfully to s3://${backup_s3_path}"
                    
                    # Write backup filename to latest.txt and upload it
                    echo "${backup_filename}" > "${latest_txt_file}"
                    if run_s3cmd put "${latest_txt_file}" "s3://${latest_txt_path}"; then
                        echo "latest.txt updated with backup filename: ${backup_filename}"
                    else
                        echo "Warning: Failed to upload latest.txt to S3." >&2
                    fi
                    rm -f "${latest_txt_file}"
                    
                    # Update last backup time
                    run_mysql_query "DELETE FROM ${DB_MANAGER}.lastBackupTime"
                    run_mysql_query "INSERT INTO ${DB_MANAGER}.lastBackupTime (timestamp) VALUES (NOW())"
                    echo "lastBackupTime updated."
                else
                    echo "Failed to upload backup to S3." >&2
                fi
                
                # Clean up temporary backup file
                rm -f "${backup_file}"
            else
                echo "Failed to create backup." >&2
            fi
        else
            echo "Backup not needed yet. Next backup in $((BACKUP_INTERVAL_SECONDS - ELAPSED_SECONDS)) seconds."
        fi
    else
        echo "No backup timestamp found in lastBackupTime table. Trying to restore database from backup..."
        restore_database
    fi
}

# Wait for services
wait_for_services

# Check and create backup if needed
backup_database