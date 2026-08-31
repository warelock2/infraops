#!/bin/sh
# Add k8s apt key
K8S_MAJOR_MINOR="$1"
mkdir -p /etc/apt/keyrings &&
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg