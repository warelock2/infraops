#!/bin/bash
# Run this ON the Proxmox host to create the cloud-init snippet
# for the ansible bootstrap user.
#
# Usage:
#   1. Copy this script over to the proxmox server
#   2. Run: sudo ./create-proxmox-snippet.sh

set -euo pipefail

SNIPPET_PATH="/var/lib/vz/snippets"

cat > "$SNIPPET_PATH/cloud-init-reboot.yaml" << 'EOF'
#cloud-config
package_update: true

write_files:
  - path: /var/run/have_not_yet_rebooted
    content: "cloud-init is running"
    permissions: "0644"

bootcmd:
  - swapoff -a
  - sed -i '/ swap / s/^/#/' /etc/fstab

packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - netplan apply

power_state:
  mode: reboot
  delay: 1
  condition: "test -f /var/lib/cloud/instance/boot-finished"
EOF
echo "Created $SNIPPET_PATH/cloud-init-reboot.yaml"
