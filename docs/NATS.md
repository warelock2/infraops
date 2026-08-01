# NATS

NATS messaging via the **midas** project — the subspace communications array. NATS/JetStream powers VM readiness signaling, IaC orchestration, and infrastructure event streams.

## Overview

- **Server**: `midas.afobl.com:4222` (TLS, JetStream enabled)
- **Stream**: `infraops` (subjects `infraops.>`, 30-minute retention)
- **Users**: 4 NATS users, passwords stored in Vault at `secret/infraops/nats`

| Context | User | Vault key | Description |
|---|---|---|---|
| `system` | `sys` | `sys_password` | NATS System Admin |
| `production` | `app` | `app_password` | NATS Production |
| `vm` | `vm` | `vm_password` | VM Bootstrap |
| `iac-orchestrator` | `iac-orchestrator` | `iac_orchestrator_password` | IaC Orchestrator |

Passwords are never stored in this repo — they come from Vault at runtime.

## Client Setup

### Prerequisites

- `vault` CLI with a valid token (see [Vault](#vault))
- `jq`
- `nats` CLI
- Network access to Vault and `midas.afobl.com:4222`

### Quick Start

Configure **all** contexts (default):

```bash
curl -sfL https://forgejo.afobl.com/warelock/infraops/raw/branch/master/scripts/init-nats-contexts.sh | bash
```

Configure **specific** contexts:

```bash
curl -sfL https://forgejo.afobl.com/warelock/infraops/raw/branch/master/scripts/init-nats-contexts.sh | bash -s -- --contexts=system,production
```

Configure a **single** context:

```bash
curl -sfL https://forgejo.afobl.com/warelock/infraops/raw/branch/master/scripts/init-nats-contexts.sh | bash -s -- --contexts=production
```

### Local Execution

If the repo is cloned locally:

```bash
scripts/init-nats-contexts.sh
scripts/init-nats-contexts.sh --contexts=system,production
scripts/init-nats-contexts.sh --contexts=production
```

View full usage:

```bash
scripts/init-nats-contexts.sh --help
```

### Contexts

`nats context ls` lists configured contexts. To delete a context:

```bash
nats context delete <context-name>
```

## Rotating Passwords

Rotation is a coordinated two-step process because the NATS server and its clients must agree on passwords:

1. **Server side** — rotate the passwords in Vault, render `conf/nats-server.conf`, and restart NATS. In the midas project on the docker host (operator only, requires Vault write access):
   ```bash
   scripts/update_service_auth_creds.sh --rotate --restart
   ```
   `--rotate` generates new 24-character passwords, writes them to Vault, then renders the server config with them. `--restart` applies the change. Run with `--rotate` alone to render without restarting.

2. **Client side** — on each machine that holds NATS contexts, refresh them from the new Vault values:
   ```bash
   curl -sfL https://forgejo.afobl.com/warelock/infraops/raw/branch/master/scripts/init-nats-contexts.sh | bash
   ```

After rotation, if VMs use the `vm` context for bootstrap signaling, regenerate the Proxmox cloud-init snippet with the new `vm_password`:

```bash
scripts/update_vm_snippet.sh
```

## Server Admin

The NATS server runs via Docker Compose in the **midas** project on the docker host.

### Health Checks

```bash
curl http://localhost:8222/healthz
curl http://localhost:8222/jsz
nats server info --context=system
```

### Stream Management

```bash
nats stream list --context=production
nats stream info infraops --context=production
nats stream delete infraops --context=production
```

## Vault

- **Path**: `secret/infraops/nats` (KV v2)
- **Keys**: `sys_password`, `app_password`, `vm_password`, `iac_orchestrator_password`
- **Token resolution** (by `init-nats-contexts.sh`):
  1. `VAULT_TOKEN` environment variable
  2. `pass tokens/vault-prod`
  3. `~/.vault-token`

Read contexts (`--contexts=...` without `--rotate`) need only read access to `secret/infraops/nats`. `--rotate` additionally needs write access.

## Troubleshooting

### `nats: command not found`

The nats CLI isn't installed. Install it with the midas client installer (on the docker host):

```bash
./clients/install-nats.sh
```

### `ERROR: No Vault token available`

Set `VAULT_TOKEN`, ensure `pass tokens/vault-prod` exists, or place a token in `~/.vault-token`.

### `ERROR: Unknown context '...'`

Valid context names: `system`, `production`, `vm`, `iac-orchestrator`.

### `ERROR: ... is required but not installed.`

Install the missing CLI (`vault`, `jq`, or `nats`), then rerun.

### Authentication errors after rotation

The server and clients are out of sync. Rerun the rotation in order:

1. `scripts/update_service_auth_creds.sh --rotate --restart` (midas, server side)
2. `init-nats-contexts.sh` (client side, all machines)

### `nats: error reading server version`

Network or TLS issue reaching `midas.afobl.com:4222`. Verify the server is up: `curl http://localhost:8222/healthz`.
