# Infrastructure as Code Change Guide

This guide defines how infrastructure changes map to semantic versioning. It is the reference for the release manager when evaluating commits and choosing a version bump flag.

## Release Manager Workflow

1. Review commits since last tag: `git log v1.0.0..HEAD --oneline`
2. Categorize each commit's impact using the table below
3. Pick the **highest-impact flag** (major wins over minor, minor wins over patch)
4. Run `./build-release.sh --<flag>`
5. Commits become release notes automatically

## Version Bump Rules

### Major (`--major`) — Breaking Changes

Infrastructure changes that break existing deployments or require manual intervention.

| Action | Example |
|---|---|
| Cluster added | Adding `banana` cluster to `infrastructure.yaml` |
| Cluster removed | Removing `mushroom` cluster |
| Host removed | Removing `docker` host |
| Network changed | Changing subnet, gateway, or DNS domain |
| VIP changed | Changing API endpoint from `192.168.0.30` to `192.168.0.40` |
| k8s major version | Upgrading from `1.28` to `1.30` |
| Schema breaking change | Removing or renaming a property |
| Template ID changed | Changing Proxmox template from `8000` to `9000` |

### Minor (`--minor`) — Non-Breaking Additions

Infrastructure additions that don't break existing deployments.

| Action | Example |
|---|---|
| Host added | Adding `monitoring` host to `infrastructure.yaml` |
| Service added | Adding `prometheus` service |
| Worker node count changed | Scaling from `2` to `3` workers |
| Control plane node count changed | Scaling from `1` to `3` control plane |
| Service instance added | Adding `vault` instance |
| IP pool range changed | Expanding `.40-.59` to `.40-.99` |
| k8s minor version | Upgrading from `1.33.0` to `1.33.1` |
| Schema property added | Adding `tls_self_signed` to `platform.proxmox` |
| New playbook or script | Adding `manage-iac-dns.yaml` |

### Patch (`--patch`) — Bug Fixes

Fixes that don't change infrastructure behavior.

| Action | Example |
|---|---|
| Playbook bug fix | Fixing drain timeout in `k8s-cluster.yaml` |
| Config correction | Fixing DNS record typo |
| Schema typo | Fixing pattern regex in `infrastructure.schema.yaml` |
| Documentation update | Updating `README.md` or `SECRETS.md` |
| Script fix | Fixing `dns-lookup.sh` fallback path |
| CI/CD fix | Fixing workflow step or image reference |
| Regenerated docs | Updating `SCHEMA_REFERENCE.md` |

### Pre-Release (`--rc`, `--dev`)

| Flag | Use Case |
|---|---|
| `--rc` | Testing a major change before making it permanent |
| `--dev` | Work-in-progress, not ready for production |

## Evaluating a Batch of Commits

When reviewing commits since the last tag, apply the **highest-impact wins** rule:

```
git log v1.0.0..HEAD --oneline
  fix: correct drain timeout in k8s-cluster.yaml        → patch
  add monitoring host to infrastructure.yaml              → minor
  fix: dns-lookup.sh Python fallback path                 → patch
```

Result: `--minor` wins. Release: `v1.1.0`.

```
  remove legacy docker host                              → major
  add vault service instance                             → minor
  fix: schema pattern for cidr                           → patch
```

Result: `--major` wins. Release: `v2.0.0`.

## Commit Message Convention

Commit messages become release notes. Use conventional commit format:

```
<type>: <description>
```

### Types

| Type | Description | Typical Flag |
|---|---|---|
| `feat:` | New feature or capability | `--minor` |
| `fix:` | Bug fix or correction | `--patch` |
| `breaking:` | Breaking change (or `feat!:`) | `--major` |
| `docs:` | Documentation only | `--patch` |
| `chore:` | Maintenance, cleanup, config | `--patch` |
| `ci:` | CI/CD workflow changes | `--patch` |
| `refactor:` | Code restructuring, no behavior change | `--patch` |

### Examples

```
feat: add monitoring host to infrastructure.yaml
fix: correct drain timeout in k8s-cluster.yaml
breaking: remove legacy docker host from infrastructure.yaml
docs: update SECRETS.md with new Forgejo secrets
chore: regenerate SCHEMA_REFERENCE.md
ci: fix enforce-iac.yaml Terraform init step
```

## Release Notes

GitHub/Gitea auto-generates release notes from commits between tags. A typical release:

```
## v1.1.0

### Features
- add monitoring host to infrastructure.yaml

### Bug Fixes
- correct drain timeout in k8s-cluster.yaml
- dns-lookup.sh Python fallback path

### Maintenance
- regenerate SCHEMA_REFERENCE.md
```

## Ambiguous Cases

| Situation | Guidance |
|---|---|
| Schema property added | `--minor` (non-breaking addition) |
| Schema property removed | `--major` (breaking change) |
| Service added | `--minor` (non-breaking addition) |
| Service removed | `--major` (breaking change) |
| k8s minor version bump | `--minor` (non-breaking upgrade) |
| k8s major version bump | `--major` (breaking upgrade) |
| `infrastructure.yaml` change | Depends on what changed — use table above |
| Ansible/Terraform change | Depends on behavior — use table above |
| Mix of changes | Highest impact wins |
