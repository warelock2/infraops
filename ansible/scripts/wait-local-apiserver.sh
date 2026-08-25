#!/bin/bash
# Wait for local API server to become healthy
NODE_IP="$1"
INVENTORY_HOSTNAME="${2:-unknown}"

ready() {
    kubectl --kubeconfig /etc/kubernetes/admin.conf \
        --server https://${NODE_IP}:6444 get --raw /readyz >/dev/null 2>&1
}

if ready; then
    echo "local API server healthy"
    exit 0
fi

for i in $(seq 1 30); do
    sleep 10
    ready && { echo "local API server healthy"; exit 0; }
done

echo "ERROR: local API server not ready on ${INVENTORY_HOSTNAME} (https://${NODE_IP}:6444)" >&2
echo "--- kubelet (last 20) ---" >&2
journalctl -u kubelet --no-pager -n 20 2>/dev/null | tail -20 >&2
echo "--- kube-apiserver container (last 20) ---" >&2
if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
    CID=$(crictl ps -a 2>/dev/null | grep kube-apiserver | head -1 | awk '{print $1}')
    if [ -n "$CID" ]; then
        crictl logs "$CID" 2>&1 | tail -20 >&2
    else
        echo "(kube-apiserver static pod container not present)" >&2
    fi
fi
exit 1