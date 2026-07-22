#!/bin/bash
# SSH break-glass logging for immutable hosts
# Installed at /etc/ssh/sshrc on hosts with immutable: true
# Logs SSH access to syslog and creates break-glass marker file

LOG_TAG="break-glass"
MARKER_FILE="/etc/infraops/break-glass"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
USER=$(whoami)
SOURCE_IP=$(echo $SSH_CONNECTION | awk '{print $1}')

# Log to syslog
logger -t "$LOG_TAG" "BREAK GLASS ACCESS: user=$USER source_ip=$SOURCE_IP timestamp=$TIMESTAMP"

# Create marker file for monitoring
mkdir -p /etc/infraops
cat > "$MARKER_FILE" << EOF
{
  "user": "$USER",
  "source_ip": "$SOURCE_IP",
  "timestamp": "$TIMESTAMP",
  "session_id": "$SSH_CONNECTION"
}
EOF
chmod 644 "$MARKER_FILE"

# Display warning banner
echo ""
echo "********************************************************************"
echo "*  WARNING: This is an IMMUTABLE host                              *"
echo "*  All access is logged and monitored                              *"
echo "*  Break glass marker has been created                             *"
echo "*  Unauthorized access will be investigated                        *"
echo "********************************************************************"
echo ""
