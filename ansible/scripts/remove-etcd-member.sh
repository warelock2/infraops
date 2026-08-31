#!/bin/sh
# Remove etcd member for a removed control plane node
set -e

NODE_NAME="$1"
HEALTHY_CP="$2"
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

OUT=""
for _ in 1 2 3 4 5; do
    OUT=$(kubectl exec -n kube-system etcd-"$HEALTHY_CP" -- \
        etcdctl --endpoints=https://127.0.0.1:2379 \
        --cacert /etc/kubernetes/pki/etcd/ca.crt \
        --cert /etc/kubernetes/pki/etcd/server.crt \
        --key /etc/kubernetes/pki/etcd/server.key \
        member list -w json 2>/dev/null | \
        python3 -c "import sys,json; m=[x for x in json.load(sys.stdin)['members'] if x['name']=='$NODE_NAME']; print(format(m[0]['ID'],'x') if m else 'ABSENT')" 2>/dev/null) && [ -n "$OUT" ] && break
    sleep 5
done

if [ "$OUT" = "ABSENT" ]; then
    echo "$NODE_NAME: no such etcd member - already removed"
    exit 0
fi

if [ -n "$OUT" ]; then
    kubectl exec -n kube-system etcd-"$HEALTHY_CP" -- \
        etcdctl --endpoints=https://127.0.0.1:2379 \
        --cacert /etc/kubernetes/pki/etcd/ca.crt \
        --cert /etc/kubernetes/pki/etcd/server.crt \
        --key /etc/kubernetes/pki/etcd/server.key \
        member remove "$OUT"
else
    echo "ERROR: could not fetch etcd member list after 5 attempts" >&2
    exit 1
fi