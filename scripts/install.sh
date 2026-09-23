#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="app"
SERVERS=1
AGENTS=2

REGISTRY_NAME="${CLUSTER_NAME}-registry"
REGISTRY_PORT="5111"
NAMESPACE="app"

IMAGE="app/branch/development:latest"
REGISTRY_IMAGE="localhost:${REGISTRY_PORT}/${IMAGE}"
DB_USERNAME="app_test-dev"

echo "==> Creating local registry"
if ! k3d registry get "$REGISTRY_NAME" >/dev/null 2>&1; then
    k3d registry create "$REGISTRY_NAME" --port "$REGISTRY_PORT"
else
    echo "Registry already exists: $REGISTRY_NAME"
fi

echo "==> Creating k3d cluster"
if ! k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
    k3d cluster create "$CLUSTER_NAME" \
        --servers "$SERVERS" \
        --agents "$AGENTS" \
        --registry-use "$REGISTRY_NAME:$REGISTRY_PORT" \
        -p "80:80@loadbalancer" \
        -p "443:443@loadbalancer"
else
    echo "Cluster already exists: $CLUSTER_NAME"
fi

echo "==> Waiting for Kubernetes nodes"
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo "==> Taint Master node"
kubectl taint node "k3d-${CLUSTER_NAME}-server-0" \
    node-role.kubernetes.io/control-plane:NoSchedule \
    --overwrite

echo "==> Configuring ServiceLB"
kubectl label node "k3d-${CLUSTER_NAME}-server-0" \
    svccontroller.k3s.cattle.io/enablelb=false \
    --overwrite

for ((i=0; i<AGENTS; i++)); do
    kubectl label node \
        "k3d-${CLUSTER_NAME}-agent-${i}" \
        svccontroller.k3s.cattle.io/enablelb=true \
        --overwrite
done

echo "==> Publishing application image"
docker image inspect "$IMAGE" >/dev/null
docker tag "$IMAGE" "$REGISTRY_IMAGE"
docker push "$REGISTRY_IMAGE"

echo "==> Creating namespace"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || \
    kubectl create namespace "$NAMESPACE"

echo "==> Creating database credentials"
if kubectl get secret app-db-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Database secret already exists."
else
    DB_PASSWORD="$(openssl rand -base64 32)"

    kubectl create secret generic app-db-credentials \
        -n "$NAMESPACE" \
        --from-literal=username="$DB_USERNAME" \
        --from-literal=password="$DB_PASSWORD"

    unset DB_PASSWORD
fi

echo "==> Installing CloudNativePG"
kubectl apply --server-side \
    -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/releases/cnpg-1.28.1.yaml

echo "==> Waiting for CloudNativePG"
kubectl rollout status \
    deployment/cnpg-controller-manager \
    -n cnpg-system \
    --timeout=180s  

echo "==> Deploying PostgreSQL"
kubectl apply -f postgres/cluster-deployment.yaml

echo "==> Waiting for PostgreSQL"
kubectl wait \
    --for=jsonpath='{.status.phase}'='Cluster in healthy state' \
    cluster/app-db \
    -n "$NAMESPACE" \
    --timeout=300s

echo "==> Installing cert-manager"
kubectl apply \
    -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.1/cert-manager.yaml

echo "==> Waiting for cert-manager"

kubectl wait \
    --for=condition=Available \
    deployment/cert-manager \
    -n cert-manager \
    --timeout=180s

kubectl wait \
    --for=condition=Available \
    deployment/cert-manager-cainjector \
    -n cert-manager \
    --timeout=180s

kubectl wait \
    --for=condition=Available \
    deployment/cert-manager-webhook \
    -n cert-manager \
    --timeout=180s

echo "==> Deploying TLS configuration"
kubectl apply -f cert-manager/issuer.yaml

echo "==> Deploying application"
kubectl apply -f app/app-deployment.yaml
kubectl apply -f app/app-service.yaml

kubectl rollout status \
    deployment/app-test \
    -n "$NAMESPACE" \
    --timeout=180s

echo "==> Deploying Ingress"
kubectl apply -f app/ingress.yaml

echo
echo "==> Installation complete"
echo
kubectl get nodes
echo
kubectl get pods -A
echo
kubectl get cluster -n "$NAMESPACE"
echo
kubectl get ingress -n "$NAMESPACE"