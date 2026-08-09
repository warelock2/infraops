# Kubernetes Access via Keycloak — Administrator's Guide

## Overview

**Keycloak** is the centralized OpenID Connect (OIDC) identity provider for
Kubernetes authentication. Instead of handing out TLS client certificates or
hand-built kubeconfigs, you manage access through Keycloak: the API server
validates tokens at request time and derives the caller's groups from the
token.

```
User runs kubectl
  → kubelogin opens browser for Keycloak login (device flow)
    → Keycloak authenticates user, issues token with groups claim
      → kubelogin passes token to the K8s API server
        → API server validates token (issuer, audience, signature)
          → API server extracts "groups" from token
            → K8s RBAC matches groups to ClusterRoleBindings
              → User gets permissions (or not)
```

## What's already in place

- **Keycloak** at `https://keycloak.afobl.com`, realm **`infraops`**
- **Admin console**: `https://keycloak.afobl.com/admin` → realm `infraops`
  (sign in as `warelock` or another master-realm admin)
- **Per-cluster OIDC client** `kubernetes-<cluster>` (public client, Device
  Authorization Grant, audience + groups mappers) — e.g. `kubernetes-mushroom`
- **API server** configured with `--oidc-*` flags pointing at the Keycloak
  realm (`https://keycloak.afobl.com/realms/infraops`)
- **Groups** per cluster: `<cluster>-admins`, `<cluster>-viewers` (e.g.
  `mushroom-admins`, `mushroom-viewers`)
- **ClusterRoleBindings** mapping those groups to roles on each cluster:
  - `<cluster>-admins-cluster-admin`: Group `<cluster>-admins` → `cluster-admin`
  - `<cluster>-viewers`: Group `<cluster>-viewers` → `view`
- **`kubelogin`** installed on admin workstations via
  `scripts/k8s-oidc-client-setup.sh`

---

## Basic Usage Workflow

### Admin side — grant access (the whole grant, ~2 minutes)

1. **Create the user** in Keycloak:
   **Users** → **Add user** (realm `infraops`):
   | Field | Value |
   |-------|-------|
   | Username | e.g. `alice` |
   | Email | alice@example.com |
   | First name / Last name | set these (see note below) |
   | Email verified | On (optional) |
   | Enabled | **On** |

   **Credentials** tab → **Set password** → temporary password →
   **Temporary = On** (forces a password change on first login).

   > **Note:** always set Email/First name/Last name. Keycloak's
   > `VERIFY_PROFILE` required action forces a profile-completion page on first
   > login when they're missing.

2. **Assign the group**: **Users** → `alice` → **Groups** tab → **Join group**
   → select `mushroom-admins` (full admin) or `mushroom-viewers` (read-only).

That's it — no cluster-side changes. RBAC is already wired via the
ClusterRoleBindings above.

### User side — set up kubectl (one time)

The user runs (on their workstation):

```bash
./scripts/k8s-oidc-client-setup.sh --cluster=mushroom
```

This installs `kubectl`/`kubelogin`/`kubectx` if missing and writes kubeconfig
entries:
- context **`mushroom`** — OIDC user (kubectl invokes `kubelogin` automatically)
- context **`mushroom-admin-cert`** — cert-based break-glass fallback

### First kubectl command

```bash
kubectl get nodes
```

1. kubelogin opens the browser to the Keycloak device-consent page
2. User logs in (first time: forced password change, then the consent screen)
3. kubelogin caches the token in `~/.kube/cache` (~24 h) and attaches it to the
   request
4. Subsequent commands are silent until the refresh token expires

Verify with:

```bash
kubectl auth whoami
# Username: https://keycloak.afobl.com/realms/infraops#alice
# Groups:   [mushroom-admins]
```

---

## Administrator Reference

### Revoking access

**Temporary** (cached token still valid until expiry):
- Disable the user: **Users** → user → **Enabled = Off**
- Remove from group: **Users** → user → **Groups** → **Leave**
- Change password: **Users** → user → **Credentials** → **Set password**

**Immediate** (force re-auth / kill switch):
- Take the action above, and the user runs:
  ```bash
  rm -rf ~/.kube/cache
  ```
  The next `kubectl` forces a fresh login, which fails if the account is
  disabled. Disabling the account is the hard cut-off (it blocks token
  refresh too).

### Multiple clusters

Each cluster gets its own client, groups, and bindings:

```
Realm: infraops
├── Client: kubernetes-mushroom   (→ --oidc-client-id=kubernetes-mushroom)
├── Client: kubernetes-banana     (→ --oidc-client-id=kubernetes-banana)
├── Group:  mushroom-admins / mushroom-viewers
├── Group:  banana-admins  / banana-viewers
└── User:   alice → mushroom-admins, banana-viewers
```

A user in multiple groups carries all of them in the token; the cluster only
honors the binding-relevant ones. The `kubernetes-<cluster>` audience mapper
ensures each cluster's tokens are scoped to that client.

Creating a new cluster end-to-end is handled by the repo's IaC:
- `keycloak-setup.yaml` creates `kubernetes-<cluster>` + `<cluster>-admins/`
  `<cluster>-viewers` (driven by `infra_platform_cluster_names`)
- `k8s-cluster.yaml` creates the matching ClusterRoleBindings

### Token claims at a glance

| Claim | Value | Used by |
|-------|-------|---------|
| `iss` | `https://keycloak.afobl.com/realms/infraops` | issuer match (`--oidc-issuer-url`) |
| `aud` | `kubernetes-<cluster>`, `account` | audience match (`--oidc-client-id`) |
| `preferred_username` | the user's Keycloak username | `--oidc-username-claim` |
| `groups` | e.g. `["mushroom-admins"]` | `--oidc-groups-claim` → RBAC |

### Gotchas

- **Issuer URL has no port.** Always use
  `https://keycloak.afobl.com/realms/infraops` — not `:8443`. Hand-written
  kubeconfigs with the `:8443` URL produce an issuer/audience mismatch and the
  API server rejects the token. `k8s-oidc-client-setup.sh` builds it correctly.
- **TLS uses the Let's Encrypt `*.afobl.com` wildcard** — kubelogin and the API
  server validate against the system CA store. No custom CA pinning.
- **Profile prompt on first login** — complete Email/First/Last name when
  creating users, or users get the `VERIFY_PROFILE` page.
- **Force re-auth** — `rm -rf ~/.kube/cache`, then run `kubectl`.
- **Inspect a token's claims**:
  ```bash
  kubelogin get-token --grant-type=device-code \
    --oidc-issuer-url=https://keycloak.afobl.com/realms/infraops \
    --oidc-client-id=kubernetes-mushroom
  ```
  then decode the JWT payload.
