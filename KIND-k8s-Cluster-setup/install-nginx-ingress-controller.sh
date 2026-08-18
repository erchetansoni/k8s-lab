#!/bin/bash

# Load kind cluster config file to get the kubernetes version
K8S_VERSION=$(grep 'image:' kind-cluster-config.yaml | head -n 1 | awk -F':' '{print $NF}')
K8S_MINOR_VERSION=$(echo "${K8S_VERSION}" | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/')
echo "🚀 The Kind cluster is using Kubernetes version ${K8S_VERSION}"

########## 🌐 Install NGINX Ingress Controller ###########################
PROVIDER=kind
echo "🌐 Checking compatible Ingress-NGINX version for Kubernetes version ${K8S_MINOR_VERSION}  ..."

# Define a compatible Ingress-NGINX version for the Kubernetes version
if [[ "${K8S_MINOR_VERSION}" =~ ^1\.(35|34|33|32|31)$ ]]; then
  INGRESS_NGINX_VERSION="controller-v1.15.1"
elif [[ "${K8S_MINOR_VERSION}" =~ ^1\.(30|29|28|27|26)$ ]]; then
  INGRESS_NGINX_VERSION="controller-v1.14.5"
elif [[ "${K8S_MINOR_VERSION}" =~ ^1\.(25|24)$ ]]; then
  INGRESS_NGINX_VERSION="controller-v1.11.8"
else
  echo "❌ Unsupported Kubernetes version ${K8S_VERSION}"
  echo "🔗 Please refer to the official site for supported versions:"
  echo "   https://github.com/kubernetes/ingress-nginx?tab=readme-ov-file#supported-versions-table"
  exit 1
fi

echo "🌐 Installing NGINX Ingress Controller version ${INGRESS_NGINX_VERSION}  ..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/${PROVIDER}/deploy.yaml

# # Optional latest version (may not be compatible with all K8s versions):
# kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/${PROVIDER}/deploy.yaml

# Wait for the deployment to be created (it might take a few seconds after apply)
echo "⏳ Waiting for NGINX Ingress Controller deployment to be created..."
for i in {1..30}; do
  if kubectl get deployment -n ingress-nginx ingress-nginx-controller > /dev/null 2>&1; then
    sleep 5 # Give it a moment to create the pods
    break
  fi
  sleep 2
done

# Wait for the NGINX Ingress Controller to be ready
echo "⏳ Waiting for NGINX Ingress Controller pods to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pods \
  --selector=app.kubernetes.io/component=controller \
  --timeout=1800s

if [ $? -eq 0 ]; then
  echo "✅ NGINX Ingress Controller is ready!"
else
  echo "❌ Timeout waiting for NGINX Ingress Controller pods."
  echo "🔍 Checking pod status..."
  kubectl get pods -n ingress-nginx
  exit 1
fi