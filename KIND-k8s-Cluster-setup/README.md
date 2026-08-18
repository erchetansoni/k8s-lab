# k8s-cluster-setup/

Local-cluster bootstrap. Brings up everything the demo needs from scratch on your laptop using [kind](https://kind.sigs.k8s.io/):

- Kubernetes cluster (kind)
- NGINX Ingress Controller
- ArgoCD (with publicly-reachable ingress at `argocd.chetan.com`)
- External Secrets Operator (ESO)

After running these, the cluster is ready to receive a `kubectl apply` of the ApplicationSet from [`argocd-demo-gitops`](https://github.com/erchetansoni/argocd-demo-gitops).

## Scripts

| Script | What it does |
|---|---|
| [create-cluster.sh](create-cluster.sh) | Creates the kind cluster, then chains nginx, ArgoCD, publish-argocd, and ESO |
| [delete-cluster.sh](delete-cluster.sh) | Tears the kind cluster down |
| [install-nginx-ingress-controller.sh](install-nginx-ingress-controller.sh) | NGINX ingress controller via the upstream YAML |
| [install-argocd.sh](install-argocd.sh) | ArgoCD core install via upstream manifests |
| [publish-argocd.sh](publish-argocd.sh) | Sets `server.insecure=true` + creates an Ingress at `argocd.chetan.com` |
| [install-eso.sh](install-eso.sh) | External Secrets Operator via Helm chart |
| [kind-cluster-config.yaml](kind-cluster-config.yaml) | Kind cluster definition (K8s version, port mappings) |

## Usage

```bash
# From the repo root (scripts use repo-root-relative paths)
./k8s-cluster-setup/create-cluster.sh
```

That's the only script you'd normally run — it chains the rest. After it finishes, the script prints the ArgoCD admin password.

## After the cluster is up

```bash
# 1. Tell ArgoCD to enable Helm-in-Kustomize and allow loading from outside the kustomization root.
kubectl patch configmap argocd-cm -n argocd --type merge -p \
  '{"data":{"kustomize.buildOptions":"--enable-helm --load-restrictor=LoadRestrictionsNone"}}'
kubectl rollout restart deploy/argocd-repo-server -n argocd

# 2. Bootstrap ESO creds + cluster store
../aws-secrets-manager/create-k8s-aws-credentials-secret.sh

# 3. Apply the ApplicationSet from the gitops repo
kubectl apply -f /path/to/argocd-demo-gitops/applicationset.yaml
```

## Browser access

Add to `/etc/hosts`:

```
127.0.0.1 argocd.chetan.com app1.chetan.com app2.chetan.com app3.chetan.com
# add per-branch hosts as you spin up envs:
127.0.0.1 app1.qa.chetan.com app2.qa.chetan.com app3.qa.chetan.com
```

Then `http://argocd.chetan.com`, `http://app1.chetan.com`, etc.