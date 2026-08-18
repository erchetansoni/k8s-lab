#!/bin/bash


########## 🚀 Creating Kind Local Cluster ###########################
K8S_VERSION=$(grep 'image:' kind-cluster-config.yaml | head -n 1 | awk -F':' '{print $NF}')
echo "🚀 The Kind cluster will be created with Kubernetes version ${K8S_VERSION}"
read -p "Do you want to proceed? (y/n): " user_input

if [[ "$user_input" != "y" && "$user_input" != "Y" ]]; then
  echo "❌ Operation canceled. Please update the Kubernetes version in the kind-cluster-config.yaml file if needed."
  exit 1
fi

echo "🚀 Creating Kind cluster with Kubernetes version ${K8S_VERSION} ..."
kind create cluster --config "./kind-cluster-config.yaml"

# Wait for all pods in kube-system namespace to be Ready
kubectl wait --namespace kube-system \
  --for=condition=Ready pods \
  --all \
  --timeout=180s

echo "✅ Kind cluster created successfully!"


# ########## 🌐 Install NGINX Ingress Controller ###########################
# chmod +x install-nginx-ingress-controller.sh
# ./install-nginx-ingress-controller.sh

########## 🌐 Install Traefik Ingress Controller ###########################
chmod +x install-treafil-ingress-controller.sh
./install-treafil-ingress-controller.sh

# ########## 🚀 Install ArgoCD ###########################
# chmod +x install-argocd.sh
# ./install-argocd.sh

# ########## 🌍 Publish ArgoCD ###########################
# chmod +x publish-argocd.sh
# ./publish-argocd.sh

# ########## 🔐 Install External Secrets Operator ###########################
# chmod +x install-eso.sh
# ./install-eso.sh