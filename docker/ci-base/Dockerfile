FROM docker.io/alpine/ansible:latest

ARG TF_VERSION=1.7.5
ARG NATS_CLI_VERSION=0.4.0

RUN apk add --no-cache curl unzip py3-pip py3-requests py3-yaml yq && \
    curl -sL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" \
      -o /tmp/terraform.zip && \
    unzip -oq /tmp/terraform.zip -d /usr/local/bin/ && \
    rm /tmp/terraform.zip && \
    curl -sL "https://github.com/nats-io/natscli/releases/download/v${NATS_CLI_VERSION}/nats-${NATS_CLI_VERSION}-linux-amd64.zip" \
      -o /tmp/nats.zip && \
    unzip -oq /tmp/nats.zip -d /tmp && \
    mv /tmp/nats-${NATS_CLI_VERSION}-linux-amd64/nats /usr/local/bin/nats && \
    rm -rf /tmp/nats* && \
    pip3 install --no-cache-dir --break-system-packages hvac pfsense-vshell check-jsonschema && \
    ansible-galaxy collection install -p /usr/share/ansible/collections \
      kubernetes.core community.general ansible.posix \
      community.hashi_vault pfrest.pfsense
