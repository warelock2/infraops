FROM docker.io/alpine:latest

# Terraform sources (lock file pins the provider versions) baked into the
# provider mirror below. Build context is the repo root (see build-ci-base.sh);
# .dockerignore keeps the context lean.
COPY terraform/ /opt/tf-provider-src/

ARG TF_VERSION=1.7.5
ARG VAULT_VERSION=1.17.3
ARG NATS_CLI_VERSION
ARG KUBECTL_VERSION=1.33.0

RUN apk add --no-cache curl unzip jq python3 py3-pip py3-requests py3-yaml wget git openssh-client && \
    # --- binaries ---
    wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && \
    chmod 755 /usr/local/bin/yq && \
    yq -V | grep -q mikefarah || { echo "ERROR: wrong yq"; exit 1; } && \
    curl -sL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" \
      -o /tmp/terraform.zip && \
    unzip -oq /tmp/terraform.zip -d /usr/local/bin/ && \
    rm /tmp/terraform.zip && \
    curl -sL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip" \
      -o /tmp/vault.zip && \
    unzip -oq /tmp/vault.zip -d /usr/local/bin/ && \
    rm /tmp/vault.zip && \
    curl -sL "https://github.com/nats-io/natscli/releases/download/v${NATS_CLI_VERSION}/nats-${NATS_CLI_VERSION}-linux-amd64.zip" \
      -o /tmp/nats.zip && \
    unzip -oq /tmp/nats.zip -d /tmp && \
    mv /tmp/nats-${NATS_CLI_VERSION}-linux-amd64/nats /usr/local/bin/nats && \
    rm -rf /tmp/nats* && \
    curl -sL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      -o /usr/local/bin/kubectl && \
    chmod 755 /usr/local/bin/kubectl && \
    # --- terraform provider mirror (offline CI) ---
    # Bake the pinned providers (bpg/proxmox, hashicorp/external, hashicorp/vault)
    # into the image so `terraform init` in CI never touches the public registry.
    # The mirror is created from terraform/.terraform.lock.hcl; the filesystem_mirror
    # config below makes init resolve providers locally. Retried because the build
    # host's route to the registry is flaky (same reason terraform-init-retry.sh
    # exists). This is the ONLY place CI touches the provider registry now.
    cd /opt/tf-provider-src && \
    for i in 1 2 3 4 5; do \
      if terraform providers mirror -platform=linux_amd64 /opt/tf-provider-mirror; then break; fi; \
      echo "WARN: providers mirror attempt $i failed; retrying in 10s..." && sleep 10; \
    done; \
    test -f /opt/tf-provider-mirror/registry.terraform.io/hashicorp/vault/index.json || \
      { echo "ERROR: provider mirror failed to build"; exit 1; } && \
    printf 'provider_installation {\n  filesystem_mirror {\n    path = "/opt/tf-provider-mirror"\n  }\n}\n' > /root/.terraformrc && \
    rm -rf /opt/tf-provider-src && \
    # --- ansible-core (core only, no bundled collections) ---
    pip3 install --break-system-packages --no-cache-dir ansible-core && \
    # --- pip packages (no-deps: deps already satisfied by apk or ansible-core) ---
    pip3 install --break-system-packages --no-cache-dir --no-deps \
      hvac pfsense-vshell && \
    # check-jsonschema pulls its own deps (click, jsonschema, referencing)
    pip3 install --break-system-packages --no-cache-dir check-jsonschema && \
    # --- ansible-galaxy collections (only what we use) ---
    ansible-galaxy collection install -p /usr/share/ansible/collections \
      kubernetes.core community.general ansible.posix \
      community.hashi_vault pfrest.pfsense && \
    # --- cleanup ---
    rm -rf /usr/lib/python3.*/site-packages/ansible_test \
           /usr/lib/python3.*/site-packages/pip \
           /usr/lib/python3.*/site-packages/__pycache__ \
           /root/.cache /tmp/*
