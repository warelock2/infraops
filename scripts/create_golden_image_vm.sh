#!/bin/bash -e
set -x

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_VMID=8000
TEMPLATE_NAME="base-ubuntu-26-04"
TEMPLATE_MEMORY=2048
TEMPLATE_CORES=2
TEMPLATE_NET0="vmbr0"
IMG_DIR="/home/warelock/projects/create_golden_image_vm/images"
CLOUDIMG_FILE="ubuntu-26.04-server-cloudimg-amd64.img"
GOLDENIMG_FILE="ubuntu-26.04-server-goldenimg-amd64.img"

# --- Use the cloudimg as an unmodified template so we only modify the goldenimg file ---
cp "$IMG_DIR/$CLOUDIMG_FILE" "$IMG_DIR/$GOLDENIMG_FILE"

# Create the pre-template VM
sudo qm create "$TEMPLATE_VMID" \
  --name "$TEMPLATE_NAME" \
  --memory "$TEMPLATE_MEMORY" \
  --cores "$TEMPLATE_CORES" \
  --net0 virtio,bridge="$TEMPLATE_NET0" \
  --scsihw virtio-scsi-pci

# Import the cloud image into real VM storage
sudo qm importdisk "$TEMPLATE_VMID" "$IMG_DIR/$GOLDENIMG_FILE" local-lvm

# Attach the imported disk
sudo qm set "$TEMPLATE_VMID" \
  --scsi0 "local-lvm:vm-${TEMPLATE_VMID}-disk-0"

# Add Cloud-Init drive (required for Terraform automation)
sudo qm set "$TEMPLATE_VMID" --ide2 local-lvm:cloudinit

# Set boot + serial console (best practice for cloud images)
sudo qm set "$TEMPLATE_VMID" \
  --boot c \
  --bootdisk scsi0 \
  --serial0 socket \
  --vga serial0

# Enable QEMU guest agent (recommended)
sudo qm set "$TEMPLATE_VMID" --agent enabled=1

# Configure cloud-init: DHCP, SSH key, user
sudo qm set "$TEMPLATE_VMID" --ipconfig0 ip=dhcp
sudo qm set "$TEMPLATE_VMID" --sshkey "$(pwd)/ansible.pub"
sudo qm set "$TEMPLATE_VMID" --ciuser ansible

# Convert VM into a template (no boot — clean slate)
sudo qm template "$TEMPLATE_VMID"

echo ""
echo "Template $TEMPLATE_VMID created successfully."
echo ""
echo "No .env file to clean up — secrets only lived in memory."