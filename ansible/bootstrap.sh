#!/bin/sh
set -e

export PYTHONWARNINGS="ignore:Unverified HTTPS request is being made"

echo "=== Ansible version ==="
ansible --version

apk add --no-cache py3-requests py3-yaml curl unzip wget
wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
chmod 755 /usr/local/bin/yq
yq -V | grep -q mikefarah || { echo "ERROR: wrong yq"; exit 1; }
ansible-galaxy collection install -r ansible/requirements.yaml

# Extract values from config/infrastructure.yaml
TF_VERSION=$(yq '.platform.terraform.version' config/infrastructure.yaml)
SERVICE_HOST=$(yq '.defaults.service_host' config/infrastructure.yaml)
DNS_DOMAIN=$(yq '.platform.proxmox.dns_domain' config/infrastructure.yaml)
SERVICE_DOMAIN="${SERVICE_HOST}.${DNS_DOMAIN}"
ADMIN_USER=$(yq '.platform.admin.user' config/infrastructure.yaml)
ADMIN_GROUP=$(yq '.platform.admin.group' config/infrastructure.yaml)

# SSH public key from environment
if [ -z "$ADMIN_SSH_PUBLIC_KEY" ]; then
  echo "ERROR: ADMIN_SSH_PUBLIC_KEY environment variable is not set." >&2
  exit 1
fi

curl -sL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip
unzip -o /tmp/terraform.zip -d /usr/local/bin/

echo "$ADMIN_SSH_PUBLIC_KEY" > /tmp/ssh_key.pub
echo "$ANSIBLE_SSH_PRIVATE_KEY" > /tmp/ansible_key
chmod 600 /tmp/ansible_key

export ANSIBLE_CONFIG=$PWD/ansible/ansible.cfg

cd terraform
terraform init -reconfigure

terraform plan -detailed-exitcode -input=false >/dev/null 2>&1 && PLAN_RC=0 || PLAN_RC=$?

if [ "$PLAN_RC" -eq 0 ]; then
  echo "Infrastructure unchanged, skipping boot wait"
elif [ "$PLAN_RC" -eq 2 ]; then
  echo "New infrastructure detected, applying..."
  terraform apply -auto-approve -input=false
  echo "Waiting 5 minutes for VMs to boot..."
  sleep 300
else
  echo "Terraform plan failed (exit $PLAN_RC), aborting."
  exit 1
fi

terraform output -json ansible_inventory > ../ansible/inventory.json
cd ..

ansible-playbook -i ansible/inventory.json ansible/playbooks/site.yaml \
  --private-key /tmp/ansible_key \
  -e "infra_platform_kubernetes_version=$(yq '.platform.kubernetes.version' config/infrastructure.yaml)" \
  -e "infra_platform_kubernetes_pod_network_cidr=$(yq '.platform.kubernetes.pod_network_cidr' config/infrastructure.yaml)" \
  -e "infra_platform_kubernetes_calico_version=$(yq '.platform.kubernetes.calico_version' config/infrastructure.yaml)" \
  -e "infra_service_domain=$SERVICE_DOMAIN" \
  -e "infra_admin_user=$ADMIN_USER" \
  -e "infra_admin_group=$ADMIN_GROUP" \
  -e "infra_ssh_key_file=/tmp/ssh_key.pub"

CLUSTER_NAMES=$(yq '.clusters[].name' config/infrastructure.yaml | paste -sd ',' -)

for KC_ENTRY in $(yq '.services.instances.keycloak[] | .name + ":" + (.port | tostring)' config/infrastructure.yaml); do
  KC_NAME=$(echo "$KC_ENTRY" | cut -d: -f1)
  KC_PORT=$(echo "$KC_ENTRY" | cut -d: -f2)

  echo "=== Keycloak Deploy: $KC_NAME ==="
  ansible-playbook -i ansible/inventory.json ansible/playbooks/keycloak-deploy.yaml \
    --private-key /tmp/ansible_key \
    -e "provision_mode=true kc_project_name=$KC_NAME kc_host_port=$KC_PORT" \
    -e "infra_service_domain=$SERVICE_DOMAIN" \
    -e "infra_admin_user=$ADMIN_USER" \
    -e "infra_admin_group=$ADMIN_GROUP" \
    -e "infra_admin_ssh_public_key='$ADMIN_SSH_PUBLIC_KEY'"

  echo "=== Keycloak Setup: $KC_NAME ==="
  KEYCLOAK_URL="https://${SERVICE_DOMAIN}:${KC_PORT}" \
    ansible-playbook -i ansible/inventory.json ansible/playbooks/keycloak-setup.yaml \
      --private-key /tmp/ansible_key \
      -e "kc_project_name=$KC_NAME" \
      -e "infra_service_domain=$SERVICE_DOMAIN" \
      -e "infra_platform_keycloak_realm=$(yq '.platform.keycloak.realm' config/infrastructure.yaml)" \
      -e "infra_platform_keycloak_auth_realm=$(yq '.platform.keycloak.auth_realm' config/infrastructure.yaml)" \
      -e "infra_platform_keycloak_admin_user=$(yq '.platform.keycloak.admin_user' config/infrastructure.yaml)" \
      -e "infra_platform_cluster_names=$CLUSTER_NAMES"
done
