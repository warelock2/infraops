#!/bin/sh
# Configure containerd with SystemdCgroup
K8S_IMAGE_REPOSITORY="{{ k8s_image_repository }}"
mkdir -p /etc/containerd &&
containerd config default > /etc/containerd/config.toml &&
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml &&
sed -i "s|sandbox_image = .*|sandbox_image = \"$K8S_IMAGE_REPOSITORY/pause:3.10\"|" /etc/containerd/config.toml