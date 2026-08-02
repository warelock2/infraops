FROM docker.io/alpine:latest

ARG TF_VERSION=1.7.5
ARG VAULT_VERSION=1.17.3
ARG NATS_CLI_VERSION
ARG KUBECTL_VERSION=1.33.0

# Retry helper: the build host's route to external download hosts is flaky
# (same reason terraform-init-retry.sh exists), so wrap downloads in retries.
RUN retry() { for i in 1 2 3 4 5; do "$@" && return 0; echo "WARN: retrying in 10s..." && sleep 10; done; return 1; } && \
    retry apk add --no-cache curl unzip jq python3 py3-pip py3-requests py3-yaml wget git openssh-client

# --- pip packages (cached independently; no binary/tool dependency) ---
# ansible-core (core only, no bundled collections)
RUN retry() { for i in 1 2 3 4 5; do "$@" && return 0; echo "WARN: retrying in 10s..." && sleep 10; done; return 1; } && \
    retry pip3 install --break-system-packages --no-cache-dir ansible-core && \
    # no-deps: deps already satisfied by apk or ansible-core
    retry pip3 install --break-system-packages --no-cache-dir --no-deps \
      hvac pfsense-vshell && \
    # check-jsonschema pulls its own deps (click, jsonschema, referencing)
    retry pip3 install --break-system-packages --no-cache-dir check-jsonschema && \
    # cleanup (kept in the same layer so it's cached together)
    rm -rf /usr/lib/python3.*/site-packages/ansible_test \
           /usr/lib/python3.*/site-packages/pip \
           /usr/lib/python3.*/site-packages/__pycache__ \
           /root/.cache /tmp/*

# --- ansible-galaxy collections (cached independently) ---
RUN retry() { for i in 1 2 3 4 5; do "$@" && return 0; echo "WARN: retrying in 10s..." && sleep 10; done; return 1; } && \
    retry ansible-galaxy collection install -p /usr/share/ansible/collections \
      kubernetes.core community.general ansible.posix \
      community.hashi_vault pfrest.pfsense

# --- binaries (terraform, vault, nats, kubectl, yq) ---
# Downloaded once; subsequent builds reuse this cached layer unless a version
# ARG changes.
RUN retry() { for i in 1 2 3 4 5; do "$@" && return 0; echo "WARN: retrying in 10s..." && sleep 10; done; return 1; } && \
    retry wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && \
    chmod 755 /usr/local/bin/yq && \
    yq -V | grep -q mikefarah || { echo "ERROR: wrong yq"; exit 1; } && \
    retry curl -sL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" \
      -o /tmp/terraform.zip && \
    unzip -oq /tmp/terraform.zip -d /usr/local/bin/ && \
    rm /tmp/terraform.zip && \
    retry curl -sL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip" \
      -o /tmp/vault.zip && \
    unzip -oq /tmp/vault.zip -d /usr/local/bin/ && \
    rm /tmp/vault.zip && \
    retry curl -sL "https://github.com/nats-io/natscli/releases/download/v${NATS_CLI_VERSION}/nats-${NATS_CLI_VERSION}-linux-amd64.zip" \
      -o /tmp/nats.zip && \
    unzip -oq /tmp/nats.zip -d /tmp && \
    mv /tmp/nats-${NATS_CLI_VERSION}-linux-amd64/nats /usr/local/bin/nats && \
    rm -rf /tmp/nats* && \
    retry curl -sL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      -o /usr/local/bin/kubectl && \
    chmod 755 /usr/local/bin/kubectl && \
    rm -rf /root/.cache /tmp/*

# --- terraform provider mirror (offline CI) ---
# Terraform sources (lock file pins the provider versions) baked into a
# filesystem_mirror so `terraform init` in CI never touches the public registry.
# Build context is the repo root (see build-ci-base.sh); .dockerignore keeps the
# context lean. Placed last: a lock-file change only invalidates this layer.
# This is the ONLY place CI touches the provider registry now.
COPY terraform/ /opt/tf-provider-src/
RUN retry() { for i in 1 2 3 4 5; do "$@" && return 0; echo "WARN: retrying in 10s..." && sleep 10; done; return 1; } && \
    cd /opt/tf-provider-src && \
    retry terraform providers mirror -platform=linux_amd64 /opt/tf-provider-mirror && \
    test -f /opt/tf-provider-mirror/registry.terraform.io/hashicorp/vault/index.json || \
      { echo "ERROR: provider mirror failed to build"; exit 1; } && \
    printf 'provider_installation {\n  filesystem_mirror {\n    path = "/opt/tf-provider-mirror"\n  }\n}\n' > /root/.terraformrc && \
    cd / && \
    rm -rf /opt/tf-provider-src
