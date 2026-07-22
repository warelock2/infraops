# Contributing to This Project

Thanks for your interest in contributing to this project! Whether you're fixing a bug, improving documentation, or adding a new feature, your contribution is welcome. This is a production-grade Infrastructure as Code platform for on-prem Kubernetes clusters. Contributions that improve portability, correctness, or documentation are especially valued.

> And if you like the project, but just don't have time to contribute, that's fine. There are other easy ways to support the project and show your appreciation:
> - Star the project on GitHub
> - Refer this project in your project's README
> - Mention the project to friends or colleagues working with Kubernetes

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [I Have a Question](#i-have-a-question)
- [I Want To Contribute](#i-want-to-contribute)
  - [Reporting Bugs](#reporting-bugs)
  - [Suggesting Enhancements](#suggesting-enhancements)
  - [Your First Code Contribution](#your-first-code-contribution)
  - [Improving The Documentation](#improving-the-documentation)
- [Development Setup](#development-setup)
- [How to Submit a Pull Request](#how-to-submit-a-pull-request)
- [Styleguides](#styleguides)
  - [Commit Messages](#commit-messages)
  - [Code Style](#code-style)
- [Security](#security)

## Code of Conduct

Be respectful, constructive, and patient. This is a production infrastructure project — contributions are reviewed carefully because mistakes can break things. Keep expectations realistic and communicate clearly.

## I Have a Question

> If you want to ask a question, we assume that you have read the available [Documentation](docs/).

Before you ask a question, search existing [Issues](/issues) that might help. If you find a suitable issue but still need clarification, add a comment there.

If you still have a question:

1. Open an [Issue](/issues/new)
2. Provide as much context as you can about what you're running into
3. Include relevant versions (Terraform, Ansible, Python, OS)

## I Want To Contribute

> **Legal Notice**: When contributing to this project, you must agree that you have authored 100% of the content, that you have the necessary rights to the content, and that the content you contribute may be provided under the project license.

### Reporting Bugs

#### Before Submitting a Bug Report

- Make sure you're using the latest version
- Determine if it's really a bug and not a configuration error on your side (check the [documentation](docs/))
- Search [existing issues](/issues) to see if the bug has already been reported
- Collect information:
  - Error messages or stack traces
  - OS and platform version
  - Terraform, Ansible, and Python versions
  - Steps to reproduce the issue

#### How to Submit a Bug Report

> **Security issues**: Do not report security vulnerabilities in public issues. Email the maintainer directly.

1. Open an [Issue](/issues/new)
2. Explain the behavior you expected and the actual behavior
3. Provide reproduction steps someone else can follow
4. Include the environment information you collected

### Suggesting Enhancements

#### Before Submitting an Enhancement

- Read the [documentation](docs/) to see if the functionality already exists
- Search [existing issues](/issues) to see if it's already been suggested
- Consider whether your idea fits the project's scope — will it be useful to most users?

#### How to Submit an Enhancement

1. Open an [Issue](/issues/new) with a clear, descriptive title
2. Describe the current behavior and what you'd expect instead
3. Explain why this enhancement would be useful
4. Include your use case

### Your First Code Contribution

Start with issues labeled "good first issue" or "documentation". The workflow is:

1. Fork the repository
2. Clone your fork
3. Create a feature branch
4. Make your changes
5. Validate locally (see [Development Setup](#development-setup))
6. Commit with conventional format (see [Commit Messages](#commit-messages))
7. Push to your fork
8. Open a pull request against `master`

CI will validate your changes before review.

### Improving The Documentation

Documentation improvements are always welcome. Key files:

- `docs/ARCHITECTURE.md` — System design and structure
- `docs/SECRETS.md` — Secrets management
- `docs/SCHEMA_REFERENCE.md` — Auto-generated from schema (run `scripts/generate-schema-docs.py` after schema changes)
- `docs/IAC_CHANGE_GUIDE.md` — Semver rules and commit conventions
- `docs/WORKFLOW.md` — Git workflow and rollback procedures

## Development Setup

### Prerequisites

- Python 3.x with `.venv`
- Terraform ~1.7
- Ansible ~10.x
- `yq` (YAML processor)
- `check-jsonschema` (schema validation)

### Local Setup

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/infraops.git
cd infraops

# Create Python virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -r ansible/requirements.txt

# Install Ansible collections
ansible-galaxy collection install -r ansible/requirements.yaml

# Validate infrastructure.yaml against schema
./scripts/validate-infra.sh
```

### Validating Changes

Before submitting a pull request, validate locally:

```bash
# Schema validation
./scripts/validate-infra.sh

# Terraform plan (see what infrastructure changes)
cd terraform
terraform init
terraform plan

# Ansible dry-run (check playbook changes)
ansible-playbook ansible/playbooks/k8s-cluster.yaml --check
```

## How to Submit a Pull Request

1. **Fork** the repository on GitHub
2. **Clone** your fork locally
3. **Create a feature branch** from `master`
4. **Make your changes** — keep commits focused and atomic
5. **Validate** your changes locally (see above)
6. **Commit** with a conventional message (see [Commit Messages](#commit-messages))
7. **Push** to your fork
8. **Open a pull request** against `master`
9. **CI runs** — validation, terraform plan, schema checks
10. **Reviewer checks** what will change before approving

The reviewer will see exactly what infrastructure changes your PR introduces before merging.

## Styleguides

### Commit Messages

Use conventional commit format:

```
<type>: <description>
```

| Type | Description | Example |
|------|-------------|---------|
| `feat:` | New feature or capability | `feat: add monitoring host to infrastructure.yaml` |
| `fix:` | Bug fix or correction | `fix: correct drain timeout in k8s-cluster.yaml` |
| `breaking:` | Breaking change | `breaking: remove legacy docker host` |
| `docs:` | Documentation only | `docs: update SECRETS.md with new Forgejo secrets` |
| `chore:` | Maintenance, cleanup | `chore: regenerate SCHEMA_REFERENCE.md` |
| `ci:` | CI/CD workflow changes | `ci: fix enforce-iac.yaml Terraform init step` |
| `refactor:` | Code restructuring | `refactor: extract DNS lookup into separate script` |

For full details on versioning rules, see [docs/IAC_CHANGE_GUIDE.md](docs/IAC_CHANGE_GUIDE.md).

### Code Style

- **Terraform**: Run `terraform fmt` before committing
- **Ansible**: Follow existing playbook conventions (see `ansible/playbooks/k8s-cluster.yaml`)
- **Python**: Follow existing script conventions (see `scripts/`)
- **Shell**: Follow existing script conventions (see `scripts/dns-lookup.sh`)

## Security

**NEVER include your `infrastructure.yaml` in pull requests.** This file contains your personal network configuration (IPs, hostnames, API tokens). A pre-push hook prevents it from being pushed to public remotes. Use `infrastructure_example.yaml` as a template when setting up your own deployment.

Other security guidelines:

- **NEVER** commit secrets, API keys, tokens, or `.tfstate` files
- **NEVER** commit SSH private keys
- **Security issues**: Email the maintainer directly — do not open a public issue

---

This guide is based on the [contributing.md](https://contributing.md/) standards. [Make your own](https://contributing.md/generator/).
