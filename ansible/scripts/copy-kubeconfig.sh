#!/bin/sh
# Copy admin kubeconfig to a user's .kube directory
ADMIN_USER="$1"
ADMIN_GROUP="$2"
KUBECONFIG_B64="{{ hostvars[(groups['k8s_control'] | sort)[0]]['k8s_admin_kubeconfig'] | b64encode }}"

mkdir -p "/home/$ADMIN_USER/.kube"
echo "$KUBECONFIG_B64" | base64 -d > "/home/$ADMIN_USER/.kube/config"
chown "$ADMIN_USER:$ADMIN_GROUP" "/home/$ADMIN_USER/.kube/config"
chmod 0600 "/home/$ADMIN_USER/.kube/config"