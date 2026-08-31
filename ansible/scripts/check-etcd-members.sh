#!/bin/sh
# Verify the surviving etcd cluster is healthy and its member count matches the
# desired number of control-plane nodes after a shrink. Runs against a known
# healthy (surviving) control-plane's local etcd, mirroring remove-etcd-member.sh.
#
# Usage: check-etcd-members.sh <expected_member_count> <healthy_control_node_name>
# Exit 0 if member count == expected AND all endpoints report healthy; else 1.
set -e

EXPECTED="$1"
HEALTHY_CP="$2"

if [ -z "$EXPECTED" ] || [ -z "$HEALTHY_CP" ]; then
  echo "ERROR: usage: check-etcd-members.sh <expected_member_count> <healthy_control_node_name>" >&2
  exit 2
fi

INOUNT=""
for _ in 1 2 3 4 5; do
  INOUNT=$(kubectl exec -n kube-system etcd-"$HEALTHY_CP" -- \
      etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert /etc/kubernetes/pki/etcd/ca.crt \
      --cert /etc/kubernetes/pki/etcd/server.crt \
      --key /etc/kubernetes/pki/etcd/server.key \
      member list -w json 2>/dev/null | \
      python3 -c "import sys,json; print(len(json.load(sys.stdin)['members']))" 2>/dev/null) && [ -n "$INOUNT" ] && break
  sleep 5
done

if [ -z "$INOUNT" ]; then
  echo "ERROR: could not fetch etcd member list from $HEALTHY_CP after 5 attempts" >&2
  exit 1
fi

echo "etcd member count on $HEALTHY_CP: $INOUNT (expected $EXPECTED)"
if [ "$INOUNT" -ne "$EXPECTED" ]; then
  echo "ERROR: etcd member count $INOUNT != expected $EXPECTED after shrink" >&2
  exit 1
fi

HEALTHY=""
for _ in 1 2 3 4 5; do
  HEALTHY_RAW=$(kubectl exec -n kube-system etcd-"$HEALTHY_CP" -- \
      etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert /etc/kubernetes/pki/etcd/ca.crt \
      --cert /etc/kubernetes/pki/etcd/server.crt \
      --key /etc/kubernetes/pki/etcd/server.key \
      endpoint health 2>/dev/null || true)
  # shellcheck disable=SC2086
  HEALTHY=$(printf '%s\n' "$HEALTHY_RAW" | grep -c 'is healthy' || true)
  # retry while the healthy count is still zero (transient blip after removal)
  if [ -n "$HEALTHY" ] && [ "$HEALTHY" -ge 1 ]; then
    break
  fi
  sleep 5
done

echo "healthy etcd endpoints on $HEALTHY_CP: $HEALTHY"
if [ -z "$HEALTHY" ] || [ "$HEALTHY" -lt 1 ]; then
  echo "ERROR: no healthy etcd endpoint on $HEALTHY_CP after shrink" >&2
  exit 1
fi

echo "OK: etcd cluster healthy with $INOUNT member(s)"
