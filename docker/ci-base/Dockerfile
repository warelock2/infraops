FROM docker.io/alpine/ansible:latest

ARG TF_VERSION=1.7.5
ARG VAULT_VERSION=1.17.3
ARG NATS_CLI_VERSION

RUN apk add --no-cache curl unzip jq py3-pip py3-requests py3-yaml wget && \
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
    pip3 install --no-cache-dir --break-system-packages hvac pfsense-vshell check-jsonschema && \
    ansible-galaxy collection install -p /usr/share/ansible/collections \
      kubernetes.core community.general ansible.posix \
      community.hashi_vault pfrest.pfsense
