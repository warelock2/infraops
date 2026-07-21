#!/bin/bash
# Run this ON the Proxmox host to create the cloud-init snippet
# for the ansible bootstrap user.
#
# Usage:
#   1. Copy this script and the ansible/files/ansible.pub file over to the proxmox server
#   2. Run: sudo ./create-proxmox-snippet.sh

set -euo pipefail

SNIPPET_PATH="/var/lib/vz/snippets"

ANSIBLE_SSH_PUBLIC_KEY=$(cat ansible.pub)

if [ -z "${ANSIBLE_SSH_PUBLIC_KEY:-}" ]; then
  echo "ERROR: ANSIBLE_SSH_PUBLIC_KEY is not set."
  echo "Usage: ANSIBLE_SSH_PUBLIC_KEY=\"ssh-ed25519 AAAA...\" $0"
  exit 1
fi

cat > "$SNIPPET_PATH/vm-bootstrap.yaml" << EOF
#cloud-config
# User data for k8s VMs. Handles ansible user creation and the first-boot
# reboot so DHCP re-registers with the correct hostname after cloud-init sets it.
# Without this, DHCP registers as "ubuntu" (the baked-in image hostname) and
# DNS never resolves the k8s hostname.
#
# bootcmd clears /root/before_first_reboot (baked into template) so Ansible
# sees no sentinel on first SSH and skips its own reboot — exactly one reboot total.
#
# NOTE: user_data_file_id is used because vendor_data_file_id does not execute
# cloud-config directives (bootcmd, power_state) in the Proxmox/bpg provider.
users:
  - name: ansible
    ssh_authorized_keys:
      - $ANSIBLE_SSH_PUBLIC_KEY
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
bootcmd:
  - rm -f /root/before_first_reboot
power_state:
  mode: reboot
  delay: 1
  condition: "true"
EOF
echo "Created $SNIPPET_PATH/vm-bootstrap.yaml"

cat > "$SNIPPET_PATH/cloud-init-reboot.yaml" << EOF
#cloud-config
# Empty. Reboot logic moved to user-data (vm-bootstrap.yaml) via
# user_data_file_id because vendor-data does not execute cloud-config
# directives in the Proxmox/bpg provider.
EOF
echo "Created $SNIPPET_PATH/cloud-init-reboot.yaml"

