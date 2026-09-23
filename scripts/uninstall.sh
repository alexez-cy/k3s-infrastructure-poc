#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="app"
REGISTRY_NAME="k3d-${CLUSTER_NAME}-registry"

echo "==> Removing k3d cluster"
if k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
    k3d cluster delete "$CLUSTER_NAME"
else
    echo "Cluster does not exist: $CLUSTER_NAME"
fi

echo "==> Removing local registry"
if k3d registry get "$REGISTRY_NAME" >/dev/null 2>&1; then
    k3d registry delete "$REGISTRY_NAME"
else
    echo "Registry does not exist: $REGISTRY_NAME"
fi

echo
echo "==> Uninstall complete"