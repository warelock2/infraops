# Kubernetes User Management via Keycloak — Administrator's Guide

## Overview

This project uses **Keycloak** as a centralized OpenID Connect (OIDC) identity provider for Kubernetes cluster authentication. Instead of distributing TLS client certificates or static kubeconfig files to every user, you manage access through Keycloak — the K8s API server validates tokens at runtime.

### How it fits together

```
User runs kubectl
  → kubelogin opens browser for Keycloak login
    → Keycloak authenticates user, issues token with groups claim
      → kubelogin passes token to K8s API server
        → API server validates token against Keycloak (issuer, audience, signature)
          → API server extracts "groups" from token
            → K8s RBAC matches groups to ClusterRoleBindings
              → User gets permissions (or not)
```

### What's already in place

- **Keycloak** at `https://keycloak.afobl.com`, realm `infraops`
- **Client `kubernetes-cli`** — public client with Device Authorization Grant, configured with the necessary protocol mappers (audience + groups)
- **API server** on each cluster configured with `--oidc-*` flags pointing to the Keycloak realm
- **`kubelogin`** installed on admin workstations as `kubectl-oidc_login`
- **`admin` user** in the `infraops` realm with `k8s-admins` group membership

---

## Administrator Workflow

### 1. Create a new user

In the Keycloak admin console (`https://keycloak.afobl.com/admin`):

1. Switch to the **`infraops`** realm (top-left dropdown)
2. **Users** → **Add user**
3. Fill in:

   | Field | Value |
   |-------|-------|
   | Username | e.g. `alice` |
   | Email | alice@example.com |
   | Email verified | On (optional) |
   | Enabled | **On** |

4. Click **Create**
5. Go to the **Credentials** tab → **Set password**
6. Enter a temporary password → **Temporary = On** (forces password change on first login) → **Set password**

### 2. Create groups (one-time setup)

Groups in Keycloak become the `groups` claim in the token, which K8s RBAC matches against.

1. **Groups** → **Create group**
2. Name the group, e.g.:
   - `cluster-a-admins` — full cluster-admin on the cluster-a cluster
   - `cluster-a-viewers` — read-only access on cluster-a
   - `cluster-a-developers` — namespace-scoped access on cluster-a
   - `cluster-b-admins` — full cluster-admin on cluster-b

### 3. Assign user to groups

1. **Users** → click the user (e.g. `alice`)
2. **Groups** tab → **Join group**
3. Select the group(s) → **Join**

A user can be in multiple groups. For example:
- `alice` → `cluster-a-admins` + `cluster-b-admins` (admin on both clusters)
- `bob` → `cluster-a-viewers` + `cluster-b-admins` (view-only on cluster-a, admin on cluster-b)
- `carol` → `cluster-b-admins` (admin on cluster-b only)

### 4. Map groups to K8s RBAC (one-time per cluster)

Each K8s cluster needs `ClusterRoleBinding` resources that map Keycloak group names to K8s roles.

Apply these manifests using an existing admin kubeconfig (cert-based break-glass or existing OIDC admin):

```yaml
# cluster-a-admins → cluster-admin
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-a-admins-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: cluster-a-admins
---
# cluster-a-viewers → view-only
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-a-viewers
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: cluster-a-viewers
---
# cluster-a-developers → namespace-scoped (example: edit access to "dev" namespace)
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: dev
  name: cluster-a-developers-edit
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: cluster-a-developers
```

**Important:** The `name` field in the `subjects` entry must match the **Keycloak group name exactly** (case-sensitive). This is the value that appears in the `groups` claim of the user's token.

### 5. User logs in

Direct the user to:

```bash
kubectl config use-context cluster-a
kubectl get nodes
```

This triggers the device authorization flow:
1. A browser window opens to the Keycloak login page
2. User enters their Keycloak username and temporary password
3. Keycloak prompts for a new password (if Temporary = On)
4. Keycloak asks for consent (one-time grant to `kubernetes-cli`)
5. Token is cached locally — subsequent commands work silently for ~24 hours

### 6. Revoking access

**Temporary** (token still valid until expiry):
- Disable the user: **Users** → user → **Enabled = Off**
- Remove from group: **Users** → user → **Groups** tab → click the group → **Leave**
- Change password: **Users** → user → **Credentials** → **Set password**

**Immediate** (force re-auth):
- Take the action above, AND instruct the user to run:
  ```bash
  rm -rf ~/.kube/cache
  ```
  This deletes the cached token so the next `kubectl` command forces a fresh login, which will fail if the user is disabled.

---

## Multiple Clusters

Each K8s cluster gets its own OIDC client in Keycloak and its own `--oidc-client-id` on the API server.

### Setup pattern

```
Keycloak Realm: infraops
├── Client: kubernetes-cluster-a   (→ cluster-a cluster, --oidc-client-id=kubernetes-cluster-a)
├── Client: kubernetes-cluster-b  (→ cluster-b,  --oidc-client-id=kubernetes-cluster-b)
│
├── Group: cluster-a-admins
├── Group: cluster-a-viewers
├── Group: cluster-b-admins
├── Group: cluster-b-viewers
│
├── User: alice  → cluster-a-admins, cluster-b-admins
├── User: bob    → cluster-a-viewers, cluster-b-admins
└── User: carol  → cluster-b-admins
```

### Each new cluster needs

1. **New Keycloak client** — public client, Device Authorization Grant enabled, protocol mappers added (Audience + Group Membership)
2. **API server `--oidc-client-id`** — set to the new client's ID (e.g. `kubernetes-cluster-b`)
3. **kubeconfig entry** — user entry with `--oidc-client-id=kubernetes-cluster-b`
4. **ClusterRoleBindings** — mapping Keycloak groups to K8s roles on the new cluster

### Cross-cluster access

A user in multiple groups gets tokens scoped to each cluster:
- On `cluster-a`: token's `aud` = `kubernetes-cluster-a`, groups include whatever cluster-a-relevant groups the user belongs to
- On `cluster-b`: token's `aud` = `kubernetes-cluster-b`, groups include cluster-b-relevant groups

The API server only validates against its own `--oidc-client-id`, so a token for one cluster cannot be reused against another.

---

## Concepts: Keycloak ↔ K8s

| Keycloak concept | K8s equivalent | Purpose |
|-----------------|----------------|---------|
| User | Subject (user) | A person or service identity |
| Group | Subject (group) | A collection of users with shared permissions |
| Client | --oidc-client-id | The registered application that requests tokens |
| Realm | (n/a) | An isolated user/group/client namespace |
| Role | ClusterRole | A named set of permissions (not directly mapped) |
| Token attribute | --oidc-username-claim | Which token field becomes the K8s username |
| Token attribute | --oidc-groups-claim | Which token field carries the user's groups |

---

## Cheat Sheet — Common Admin Tasks

| Task | Where |
|------|-------|
| Add user | Keycloak → Users → Add user |
| Delete user | Keycloak → Users → click user → Delete |
| Reset password | Keycloak → Users → click user → Credentials → Set password |
| Create group | Keycloak → Groups → Create group |
| Add user to group | Keycloak → Users → click user → Groups → Join group |
| Remove user from group | Keycloak → Users → click user → Groups → Leave |
| Map group to K8s role | Apply ClusterRoleBinding on the target cluster |
| Force re-auth | `rm -rf ~/.kube/cache` then run `kubectl get nodes` |
| Check token claims | `kubelogin get-token --grant-type=device-code --oidc-client-id=kubernetes-cli --oidc-issuer-url=https://keycloak.afobl.com/realms/infraops --certificate-authority=~/.kube/oidc-ca.pem` and decode the JWT |
