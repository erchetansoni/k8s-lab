#!/bin/bash

# Extract cluster name from config
CLUSTER_NAME=$(grep '^name:' kind-cluster-config.yaml | awk '{print $2}')

if [ -z "$CLUSTER_NAME" ]; then
    echo "❌ Could not find cluster name in kind-cluster-config.yaml"
    exit 1
fi

echo "⚠️  You are about to delete the Kind cluster: ${CLUSTER_NAME}"
read -p "Do you want to proceed? (y/n): " user_input

if [[ "$user_input" != "y" && "$user_input" != "Y" ]]; then
  echo "❌ Operation canceled."
  exit 0
fi

echo "🚀 Deleting Kind cluster ${CLUSTER_NAME} ..."
kind delete cluster --name "${CLUSTER_NAME}"

echo "✅ Kind cluster deleted successfully!"