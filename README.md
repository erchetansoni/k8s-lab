
# KIND + Traefik Gateway API — Modern Kubernetes HTTPS Lab

## Goal

This lab demonstrates a modern Kubernetes traffic architecture on Windows using KIND:

```text
Browser
  |
  | https://app.chetan.local
  v
Windows 127.0.0.1:443
  |
  v
Docker Desktop / KIND
  |
  v
Traefik Gateway Controller
  |
  v
Gateway API
  |
  +--> GatewayClass
  |
  +--> Gateway
  |
  +--> HTTPRoute
          |
          v
     ClusterIP Service
          |
          v
     foo-app Pods
```

### Deliberate design choices

This lab does **not** use:

- `Service: type: NodePort`
- `Service: type: LoadBalancer`
- `cloud-provider-kind`
- Kubernetes Ingress
- `--privileged`
- `hostNetwork: true`
- `hostPID`
- `hostIPC`
- `NET_ADMIN`
- `NET_RAW`
- Docker socket (`/var/run/docker.sock`)

The only deliberately host/network-sensitive settings are:

- KIND `extraPortMappings` for TCP 80/443
- Traefik `hostPort` 80/443
- `NET_BIND_SERVICE` so a non-root Traefik process can bind to 80/443

**Corporate security checkpoint:** if your organization's policy prohibits `hostPort` or `NET_BIND_SERVICE`, stop before installing Traefik and obtain approval/use another architecture.

---

# 1. Prerequisites

On Windows, verify:

```powershell
docker version
kind version
kubectl version --client
helm version
```

Git for Windows is useful because it includes OpenSSL. In this lab we used:

```powershell
& "C:\Program Files\Git\usr\bin\openssl.exe" version
```

Expected:

```text
OpenSSL 3.x.x
```

---

# 2. Create the working directory

```powershell
mkdir C:\kind-gateway-lab
cd C:\kind-gateway-lab
```

Example project layout:

```text
C:\kind-gateway-lab\
│
├── kind-cluster-config.yaml
├── traefik-values.yaml
├── traefik-rendered.yaml
├── gateway-lab.yaml
├── openssl-app.cnf
├── app.chetan.local.crt
└── app.chetan.local.key
```

Do **not** commit the private key to Git.

Recommended `.gitignore`:

```gitignore
*.key
*.pfx
```

---

# 3. Create the KIND cluster

Create `kind-cluster-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4

name: gitops-demo-cluster

nodes:

  - role: control-plane

    image: kindest/node:v1.36.1

    extraPortMappings:

      # Windows 127.0.0.1:80
      #        |
      #        v
      # KIND node :80
      - containerPort: 80
        hostPort: 80
        listenAddress: "127.0.0.1"
        protocol: TCP

      # Windows 127.0.0.1:443
      #        |
      #        v
      # KIND node :443
      - containerPort: 443
        hostPort: 443
        listenAddress: "127.0.0.1"
        protocol: TCP

  # Workers can be added later:
  #
  # - role: worker
  # - role: worker
```

Create:

```powershell
kind create cluster --config .\kind-cluster-config.yaml
```

Verify:

```powershell
kubectl get nodes
```

Expected:

```text
NAME                              STATUS   ROLES
gitops-demo-cluster-control-plane Ready    control-plane
```

Check the Docker port mappings:

```powershell
docker port gitops-demo-cluster-control-plane
```

Expected:

```text
80/tcp -> 127.0.0.1:80
443/tcp -> 127.0.0.1:443
```

### What happened?

KIND created a Kubernetes node as a Docker container.

The `extraPortMappings` explicitly connect:

```text
Windows :80  -> KIND node :80
Windows :443 -> KIND node :443
```

No Kubernetes Service is involved yet.

---

# 4. Install Gateway API CRDs

Gateway API provides the Kubernetes API resources used by the lab.

Install the Standard channel CRDs:

```powershell
kubectl apply --server-side `
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
```

Verify:

```powershell
kubectl get crd | Select-String "gateway.networking.k8s.io"
```

Important resources include:

```text
gatewayclasses.gateway.networking.k8s.io
gateways.gateway.networking.k8s.io
httproutes.gateway.networking.k8s.io
```

### What happened?

We installed the **API definitions**, not a traffic proxy.

At this point Kubernetes understands objects such as:

```text
GatewayClass
Gateway
HTTPRoute
```

But nothing is processing those objects yet.

---

# 5. Add the Traefik Helm repository

```powershell
helm repo add traefik https://traefik.github.io/charts
helm repo update
```

Check the chart:

```powershell
helm show chart traefik/traefik
```

---

# 6. Configure Traefik

Create `traefik-values.yaml`:

```yaml
deployment:
  enabled: true
  kind: DaemonSet

# Do NOT use hostNetwork.
hostNetwork: false

ports:

  web:
    port: 80
    containerPort: 80
    hostPort: 80
    exposedPort: 80
    protocol: TCP

  websecure:
    port: 443
    containerPort: 443
    hostPort: 443
    exposedPort: 443
    protocol: TCP

    http:
      tls:
        enabled: true

providers:

  kubernetesGateway:
    enabled: true

  # We are intentionally using Gateway API only.
  kubernetesCRD:
    enabled: false

  kubernetesIngress:
    enabled: false

gateway:
  enabled: false

gatewayClass:
  enabled: false

ingressClass:
  enabled: false

securityContext:

  capabilities:
    drop:
      - ALL

    add:
      - NET_BIND_SERVICE

  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true

log:
  level: INFO

accessLog:
  enabled: true
```

### Why DaemonSet?

We use:

```yaml
kind: DaemonSet
```

because Traefik is using `hostPort`.

With one KIND node, we get one Traefik Pod.

If the cluster later has multiple nodes, the DaemonSet places Traefik on each eligible node.

### Why `hostPort`?

We want:

```text
KIND node :80  -> Traefik :80
KIND node :443 -> Traefik :443
```

without exposing a Kubernetes NodePort.

### Why `NET_BIND_SERVICE`?

Linux normally treats ports below 1024 as privileged ports.

`NET_BIND_SERVICE` allows the non-root Traefik process to bind to ports 80/443.

It is **not** the same as:

```text
--privileged
```

and we explicitly drop all other capabilities.

---

# 7. SECURITY CHECKPOINT — render before installing

Do not blindly install a Helm chart in a corporate environment.

Render it first:

```powershell
helm template traefik traefik/traefik `
  --namespace traefik `
  --create-namespace `
  --values .\traefik-values.yaml `
  > .\traefik-rendered.yaml
```

Inspect security-sensitive settings:

```powershell
Select-String `
  -Path .\traefik-rendered.yaml `
  -Pattern "privileged|hostNetwork|hostPID|hostIPC|NET_ADMIN|NET_RAW|NET_BIND_SERVICE|hostPort"
```

Expected relevant settings:

```text
--entryPoints.web.address=:80/tcp
--entryPoints.websecure.address=:443/tcp
hostPort: 80
hostPort: 443
NET_BIND_SERVICE
hostNetwork: false
```

You should NOT find:

```text
privileged: true
hostNetwork: true
hostPID: true
hostIPC: true
NET_ADMIN
NET_RAW
/var/run/docker.sock
```

Also check for Docker socket access:

```powershell
Select-String `
  -Path .\traefik-rendered.yaml `
  -Pattern "docker.sock|/var/run/docker"
```

Ideally there is no output.

---

# 8. Install Traefik

Only after the rendered configuration passes your security review:

```powershell
helm install traefik traefik/traefik `
  --namespace traefik `
  --create-namespace `
  --values .\traefik-values.yaml `
  --wait
```

If Traefik is already installed and you are changing values:

```powershell
helm upgrade traefik traefik/traefik `
  --namespace traefik `
  --values .\traefik-values.yaml `
  --wait
```

Check:

```powershell
kubectl get pods -n traefik
```

Expected:

```text
traefik-xxxxx   1/1   Running
```

---

# 9. Verify Traefik security after installation

Check privileged:

```powershell
kubectl get pod -n traefik `
  -o jsonpath="{.items[0].spec.containers[0].securityContext.privileged}"
```

Expected:

```text
false
```

Check hostNetwork:

```powershell
kubectl get pod -n traefik `
  -o jsonpath="{.items[0].spec.hostNetwork}"
```

Expected:

```text
false
```

Check capabilities:

```powershell
kubectl get pod -n traefik `
  -o jsonpath="{.items[0].spec.containers[0].securityContext.capabilities}"
```

Expected to contain only:

```text
NET_BIND_SERVICE
```

Check privilege escalation:

```powershell
kubectl get pod -n traefik `
  -o jsonpath="{.items[0].spec.containers[0].securityContext.allowPrivilegeEscalation}"
```

Expected:

```text
false
```

---

# 10. Verify Traefik Gateway provider

```powershell
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50
```

Look for:

```text
Starting provider *gateway.Provider
```

That means Traefik is watching Gateway API resources.

---

# 11. Test Traefik before creating a Gateway

Run:

```powershell
curl.exe -v http://127.0.0.1
```

Expected:

```text
HTTP/1.1 404 Not Found
```

This is GOOD.

It proves:

```text
Browser/curl
   |
   v
127.0.0.1:80
   |
   v
KIND
   |
   v
Traefik
   |
   v
404
```

The 404 exists because we have not created any Gateway/HTTPRoute yet.

---

# 12. Create the HTTPS certificate

Git for Windows provides OpenSSL:

```powershell
& "C:\Program Files\Git\usr\bin\openssl.exe" version
```

Create an OpenSSL configuration:

```powershell
@"
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = app.chetan.local

[v3_req]
subjectAltName = DNS:app.chetan.local
"@ | Set-Content .\openssl-app.cnf
```

Generate the certificate:

```powershell
& "C:\Program Files\Git\usr\bin\openssl.exe" req `
  -x509 `
  -nodes `
  -newkey rsa:2048 `
  -keyout app.chetan.local.key `
  -out app.chetan.local.crt `
  -days 365 `
  -config .\openssl-app.cnf
```

Verify the SAN:

```powershell
& "C:\Program Files\Git\usr\bin\openssl.exe" x509 `
  -in .\app.chetan.local.crt `
  -noout `
  -subject `
  -ext subjectAltName
```

Expected:

```text
subject=CN=app.chetan.local

X509v3 Subject Alternative Name:
    DNS:app.chetan.local
```

### Important

This is a self-signed certificate.

Therefore:

```text
curl.exe -k ...
```

will work, but the browser may warn that the certificate is not trusted.

Later, create a local CA and trust it in Windows if you want the browser to show a clean lock icon.

---

# 13. Create the Kubernetes TLS Secret

```powershell
kubectl create secret tls chetan-local-tls `
  --cert=.\app.chetan.local.crt `
  --key=.\app.chetan.local.key
```

Verify:

```powershell
kubectl get secret chetan-local-tls
```

Expected:

```text
NAME               TYPE                DATA
chetan-local-tls   kubernetes.io/tls   2
```

The certificate and private key should not be committed to Git.

---

# 14. Create the application and Gateway API resources

Create `gateway-lab.yaml`.

```yaml
# ============================================================
# MODERN KUBERNETES GATEWAY API LAB
# ============================================================


# ============================================================
# 1. GatewayClass
# ============================================================

apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass

metadata:
  name: traefik

spec:
  controllerName: traefik.io/gateway-controller


---
# ============================================================
# 2. Gateway
# ============================================================

apiVersion: gateway.networking.k8s.io/v1
kind: Gateway

metadata:
  name: main-gateway
  namespace: default

spec:

  gatewayClassName: traefik

  listeners:

    # --------------------------------------------------------
    # HTTP listener
    # --------------------------------------------------------

    - name: http

      protocol: HTTP

      port: 80

      hostname: "*.chetan.local"

      allowedRoutes:
        namespaces:
          from: Same


    # --------------------------------------------------------
    # HTTPS listener
    # --------------------------------------------------------

    - name: https

      protocol: HTTPS

      port: 443

      hostname: "*.chetan.local"

      tls:

        mode: Terminate

        certificateRefs:

          - name: chetan-local-tls

      allowedRoutes:
        namespaces:
          from: Same


---
# ============================================================
# 3. Application Deployment
# ============================================================

apiVersion: apps/v1
kind: Deployment

metadata:
  name: foo-app

spec:

  replicas: 2

  selector:

    matchLabels:
      app: foo-app

  template:

    metadata:

      labels:
        app: foo-app

    spec:

      containers:

        - name: foo-app

          image: registry.k8s.io/e2e-test-images/agnhost:2.39

          command:

            - /agnhost
            - serve-hostname
            - --http=true
            - --port=8080

          ports:

            - name: http
              containerPort: 8080


---
# ============================================================
# 4. ClusterIP Service
# ============================================================

apiVersion: v1
kind: Service

metadata:
  name: foo-service

spec:

  type: ClusterIP

  selector:
    app: foo-app

  ports:

    - name: http

      port: 8080

      targetPort: 8080


---
# ============================================================
# 5. HTTPRoute
#
# https://app.chetan.local
#        |
#        v
# main-gateway :443
#        |
#        v
# foo-route
#        |
#        v
# foo-service
#        |
#        v
# foo-app
# ============================================================

apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute

metadata:
  name: foo-route

spec:

  parentRefs:

    - name: main-gateway

      sectionName: https

  hostnames:

    - "app.chetan.local"

  rules:

    - matches:

        - path:

            type: PathPrefix

            value: /

      backendRefs:

        - name: foo-service

          port: 8080
```

Notice that the TLS Secret is **not** in this YAML.

It is created separately because it contains private-key material.

---

# 15. Apply the Kubernetes application

```powershell
kubectl apply -f .\gateway-lab.yaml
```

Expected:

```text
gatewayclass.gateway.networking.k8s.io/traefik created
gateway.gateway.networking.k8s.io/main-gateway created
deployment.apps/foo-app created
service/foo-service created
httproute.gateway.networking.k8s.io/foo-route created
```

---

# 16. Verify the application

Pods:

```powershell
kubectl get pods
```

Expected:

```text
foo-app-xxxxx   1/1   Running
foo-app-yyyyy   1/1   Running
```

Service:

```powershell
kubectl get svc
```

Expected:

```text
foo-service   ClusterIP   10.x.x.x   <none>   8080/TCP
```

This is important:

```text
Service = ClusterIP
```

We intentionally do NOT use:

```text
NodePort
LoadBalancer
```

---

# 17. Verify GatewayClass

```powershell
kubectl get gatewayclass
```

Expected:

```text
NAME      CONTROLLER                      ACCEPTED
traefik   traefik.io/gateway-controller   True
```

The important relationship is:

```text
GatewayClass
     |
     | controllerName
     v
Traefik Gateway Controller
```

---

# 18. Verify Gateway

```powershell
kubectl get gateway
```

Expected:

```text
NAME           CLASS     PROGRAMMED
main-gateway   traefik   True
```

Detailed:

```powershell
kubectl describe gateway main-gateway
```

You want:

```text
Accepted: True
Programmed: True
```

For the listeners you want:

```text
http
  Accepted: True
  ResolvedRefs: True
  Programmed: True

https
  Accepted: True
  ResolvedRefs: True
  Programmed: True
```

---

# 19. Verify HTTPRoute

```powershell
kubectl get httproute
```

Expected:

```text
NAME        HOSTNAMES
foo-route   ["app.chetan.local"]
```

Detailed:

```powershell
kubectl describe httproute foo-route
```

You want:

```text
Accepted: True
ResolvedRefs: True
```

The important relationship is:

```text
HTTPRoute
    |
    | parentRefs
    v
main-gateway
    |
    | backendRefs
    v
foo-service
```

---

# 20. Configure Windows DNS

Edit:

```text
C:\Windows\System32\drivers\etc\hosts
```

Add:

```text
127.0.0.1 app.chetan.local
```

Verify:

```powershell
Resolve-DnsName app.chetan.local
```

Expected:

```text
Address: 127.0.0.1
```

---

# 21. Test the complete HTTPS path

Use:

```powershell
curl.exe -k https://app.chetan.local
```

Expected:

```text
foo-app-7854866cc6-r6m5v
```

The exact Pod name will differ.

The successful test from the working lab returned the application Pod hostname, proving the complete request path worked.

---

# 22. Test from the browser

Open:

```text
https://app.chetan.local
```

The request path is:

```text
Browser
    |
    | HTTPS
    v
Windows 127.0.0.1:443
    |
    v
KIND port mapping
    |
    v
KIND node :443
    |
    v
Traefik hostPort :443
    |
    v
Gateway :443
    |
    v
HTTPRoute
    |
    v
ClusterIP Service
    |
    v
foo-app Pods
```

---

# 23. Understand each Kubernetes layer

## GatewayClass

```yaml
kind: GatewayClass
```

Answers:

> Which controller implements this Gateway?

In this lab:

```text
GatewayClass
     |
     v
Traefik
```

---

## Gateway

```yaml
kind: Gateway
```

Answers:

> Where does traffic enter Kubernetes, and which listeners are exposed?

Here:

```text
HTTP  :80
HTTPS :443
```

The Gateway also references:

```text
chetan-local-tls
```

for TLS termination.

---

## HTTPRoute

```yaml
kind: HTTPRoute
```

Answers:

> What should happen to an HTTP request?

Here:

```text
Host: app.chetan.local
Path: /
       |
       v
foo-service:8080
```

---

## Service

```yaml
kind: Service

spec:
  type: ClusterIP
```

Provides stable internal Kubernetes networking.

The Service selects:

```yaml
app: foo-app
```

and forwards traffic to the Pods.

---

## Deployment

```yaml
kind: Deployment
replicas: 2
```

Creates and maintains two application Pods.

The Service load-balances between the matching Pods.

---

# 24. The complete architecture

```text
                         INTERNET
                            X
                            |
                     Not exposed publicly
                            |
                            v
                     Windows Browser
                            |
                            |
                  https://app.chetan.local
                            |
                            v
                 127.0.0.1:443
                            |
                            v
                 Docker Desktop
                            |
                            v
                KIND control-plane node
                            |
                            |
                         :443
                            |
                            v
                 Traefik Gateway Controller
                            |
                            v
                       GatewayClass
                         "traefik"
                            |
                            v
                       main-gateway
                            |
                         HTTPS :443
                            |
                            v
                       HTTPRoute
                     "foo-route"
                            |
                            v
                      foo-service
                        ClusterIP
                            |
                    +-------+-------+
                    |               |
                    v               v
               foo-app Pod     foo-app Pod
                    #1              #2
```

---

# 25. Why this is a modern Kubernetes architecture

The important thing is that the application does not need to know about the infrastructure.

The application only needs:

```text
Deployment
Service
```

Traffic infrastructure is expressed separately:

```text
GatewayClass
Gateway
HTTPRoute
```

That separation is one of the major reasons Gateway API is useful.

Conceptually:

```text
Infrastructure
      |
      v
GatewayClass
      |
      v
Gateway
      |
      v
Application routing
      |
      v
HTTPRoute
      |
      v
Application
      |
      v
Service
      |
      v
Pods
```

---

# 26. Clean rebuild from scratch

When you want to demonstrate the entire lab again, you can destroy the Kubernetes environment and recreate it.

## Delete the KIND cluster

```powershell
kind delete cluster --name gitops-demo-cluster
```

Verify:

```powershell
kind get clusters
```

The cluster should no longer be listed.

## Recreate

```powershell
kind create cluster --config .\kind-cluster-config.yaml
```

Then repeat:

```text
1. Install Gateway API CRDs
2. Add/update Traefik Helm repository
3. Render Traefik values
4. Security-review rendered YAML
5. Install Traefik
6. Verify Traefik security
7. Test 127.0.0.1:80 -> 404
8. Create TLS certificate
9. Create TLS Secret
10. Apply gateway-lab.yaml
11. Verify GatewayClass
12. Verify Gateway
13. Verify HTTPRoute
14. Verify Pods/Service
15. Configure Windows hosts file
16. curl -k https://app.chetan.local
17. Open browser
```

---

# 27. Fast rebuild command sequence

Once you understand the individual steps, this is the condensed version.

```powershell
# 1. KIND
kind create cluster --config .\kind-cluster-config.yaml

# 2. Gateway API
kubectl apply --server-side `
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

# 3. Traefik
helm repo add traefik https://traefik.github.io/charts
helm repo update

# 4. ALWAYS render first
helm template traefik traefik/traefik `
  --namespace traefik `
  --create-namespace `
  --values .\traefik-values.yaml `
  > .\traefik-rendered.yaml

# 5. Security review
Select-String `
  -Path .\traefik-rendered.yaml `
  -Pattern "privileged|hostNetwork|hostPID|hostIPC|NET_ADMIN|NET_RAW|NET_BIND_SERVICE|hostPort"

# 6. Install
helm install traefik traefik/traefik `
  --namespace traefik `
  --create-namespace `
  --values .\traefik-values.yaml `
  --wait

# 7. Verify
kubectl get pods -n traefik

# 8. Test Traefik
curl.exe -v http://127.0.0.1

# Expected before Gateway:
# HTTP/1.1 404 Not Found

# 9. Create TLS Secret
kubectl create secret tls chetan-local-tls `
  --cert=.\app.chetan.local.crt `
  --key=.\app.chetan.local.key

# 10. Deploy Gateway + application
kubectl apply -f .\gateway-lab.yaml

# 11. Verify
kubectl get gatewayclass
kubectl get gateway
kubectl get httproute
kubectl get pods
kubectl get svc

# 12. Test
curl.exe -k https://app.chetan.local
```

---

# 28. Troubleshooting checklist

## Traefik Pod is not Running

```powershell
kubectl get pods -n traefik
kubectl describe pod -n traefik -l app.kubernetes.io/name=traefik
kubectl logs -n traefik -l app.kubernetes.io/name=traefik
```

## `curl http://127.0.0.1` gives Empty reply

Check:

```powershell
kubectl describe daemonset traefik -n traefik
```

The entrypoints should be:

```text
--entryPoints.web.address=:80/tcp
--entryPoints.websecure.address=:443/tcp
```

NOT:

```text
--entryPoints.web.address=127.0.0.1:80/tcp
```

## Gateway is not Programmed

```powershell
kubectl describe gateway main-gateway
```

Check:

```text
Accepted
Programmed
ResolvedRefs
```

## HTTPRoute isn't accepted

```powershell
kubectl describe httproute foo-route
```

Check:

```text
Accepted: True
ResolvedRefs: True
```

## TLS error

Check:

```powershell
kubectl get secret chetan-local-tls
```

Then:

```powershell
kubectl describe gateway main-gateway
```

Make sure:

```yaml
certificateRefs:
  - name: chetan-local-tls
```

exists in the same namespace as the Gateway.

## Browser says certificate isn't trusted

That is expected with a self-signed certificate.

Test first:

```powershell
curl.exe -k https://app.chetan.local
```

Later, use a local CA and trust the CA in Windows.

---

# 29. Security model for this lab

The security-sensitive components were deliberately kept explicit.

### Host exposure

```yaml
extraPortMappings:
  hostPort: 80
  hostPort: 443
```

This means Windows only exposes:

```text
127.0.0.1:80
127.0.0.1:443
```

### Traefik

```yaml
hostNetwork: false
```

Traefik does not share the host network namespace.

### Privileges

```yaml
capabilities:
  drop:
    - ALL

  add:
    - NET_BIND_SERVICE
```

Only the required capability is added.

### Privilege escalation

```yaml
allowPrivilegeEscalation: false
```

### Root

```yaml
runAsNonRoot: true
```

### Docker socket

No:

```text
/var/run/docker.sock
```

### Kubernetes exposure

The application Service is:

```yaml
type: ClusterIP
```

There is no NodePort.

There is no LoadBalancer Service.

---

# 30. Things needs to understand carefully

A useful explanation is:

> "The browser doesn't connect directly to a Kubernetes Pod. The request first reaches the Gateway infrastructure. Gateway API then uses an HTTPRoute to decide which Kubernetes Service should receive the request. The Service selects the application Pods."

Then show:

```text
GatewayClass
    ↓
Who implements the Gateway?

Gateway
    ↓
Where does traffic enter?

HTTPRoute
    ↓
Where should this request go?

Service
    ↓
Which application endpoints?

Pods
    ↓
Where is the application actually running?
```

That gives students a clean mental model of modern Kubernetes networking without hiding the individual components behind a single `Ingress` object.

---

# 31. Current verified result

The working lab reached this final state:

```text
GatewayClass:
traefik
Accepted=True

Gateway:
main-gateway
Programmed=True

HTTPRoute:
foo-route
Accepted=True
ResolvedRefs=True

Service:
foo-service
TYPE=ClusterIP

HTTPS request:
https://app.chetan.local

Response:
foo-app-7854866cc6-r6m5v
```

The working terminal output confirms the TLS Secret was created, GatewayClass was accepted, Gateway was programmed, HTTPRoute references were resolved, and the final HTTPS request returned the `foo-app` Pod hostname. fileciteturn4file0L44-L52 fileciteturn4file0L53-L74 fileciteturn4file0L111-L145 fileciteturn4file0L210-L225 fileciteturn4file0L232-L234


---

# 32. What changes when moving this design to Production?

The most important concept is:

> **Gateway API does not require a Kubernetes `Service: LoadBalancer`.**

Gateway API is an API model. A `Gateway` represents traffic-handling infrastructure and can be implemented by an in-cluster proxy or by infrastructure such as a cloud load balancer. Kubernetes explicitly describes a Gateway as an instance of traffic-handling infrastructure that can represent a cloud load balancer or an in-cluster proxy. citeturn0search4

So the answer is:

```text
Production DOES need a reachable network entry point.

Production does NOT necessarily require:
Service type: LoadBalancer
```

The exact implementation depends on where Kubernetes is running.

---

# 33. Local Lab vs Production

Our KIND lab currently looks like this:

```text
Browser
   |
   | 127.0.0.1:443
   v
Windows
   |
   v
KIND port mapping
   |
   v
KIND node :443
   |
   v
Traefik hostPort :443
   |
   v
Gateway
   |
   v
HTTPRoute
   |
   v
ClusterIP Service
   |
   v
Pods
```

This is deliberately optimized for:

- local development
- demonstrations
- teaching
- avoiding NodePort
- avoiding a privileged container
- keeping the application Service as ClusterIP

It is **not** the architecture I would copy unchanged into production.

---

# 34. Recommended Production Architecture

For a typical cloud Kubernetes production environment, a very common architecture is:

```text
                         Internet
                            |
                            v
                    DNS: app.example.com
                            |
                            v
                 Cloud Load Balancer
                  (L4/L7 depending
                   on architecture)
                            |
                            v
                 Kubernetes Gateway
                            |
                            v
                Gateway API Controller
                      / Traefik
                            |
                            v
                       HTTPRoute
                            |
                            v
                    ClusterIP Service
                            |
                 +----------+----------+
                 |                     |
                 v                     v
              Pod #1                Pod #2
                 |                     |
                 +----------+----------+
                            |
                            v
                       Pod #3 ...
```

The key difference is:

```text
LOCAL:

Windows :443
    |
KIND port mapping
    |
Traefik hostPort


PRODUCTION:

Internet
    |
Cloud Load Balancer
    |
Traefik
```

---

# 35. Do we need `Service: LoadBalancer` in Production?

## Option A — Most common with a Traefik-based design

Yes, **a `LoadBalancer` Service is often used to expose the Traefik data plane**.

For example:

```yaml
apiVersion: v1
kind: Service

metadata:
  name: traefik

spec:

  type: LoadBalancer

  selector:
    app.kubernetes.io/name: traefik

  ports:

    - name: web
      port: 80
      targetPort: 80

    - name: websecure
      port: 443
      targetPort: 443
```

The cloud provider sees:

```text
Service type = LoadBalancer
```

and provisions/attaches the external load-balancing infrastructure.

The traffic then becomes:

```text
Internet
   |
   v
Cloud Load Balancer
   |
   v
Traefik Pods
   |
   v
Gateway
   |
   v
HTTPRoute
   |
   v
ClusterIP Service
   |
   v
Application Pods
```

Notice that the **application Service remains ClusterIP**.

Only the **Gateway controller's entry point** is externally exposed.

---

# 36. But `LoadBalancer` is NOT the only production option

There are several valid production patterns.

## Pattern 1 — Cloud Load Balancer + Traefik

This is a very straightforward architecture:

```text
Internet
   |
Cloud LB
   |
Traefik
   |
Gateway API
   |
HTTPRoute
   |
ClusterIP Services
```

Example:

```text
AWS
    Network Load Balancer / ALB
             |
             v
          Traefik
```

or:

```text
Azure
    Azure Load Balancer / Application Gateway
             |
             v
          Traefik
```

or:

```text
GCP
    Google Cloud Load Balancer
             |
             v
          Gateway implementation
```

The exact choice depends on whether you want L4 or L7 load balancing, TLS termination location, WAF integration, source IP handling, cost, and operational ownership.

---

# 37. Pattern 2 — Cloud-native Gateway API controller

Another production approach is to use a Gateway API implementation that integrates directly with the cloud provider's load-balancing infrastructure.

Conceptually:

```text
GatewayClass
     |
     v
Cloud Gateway Controller
     |
     v
Cloud Load Balancer
     |
     v
HTTPRoute
     |
     v
Service
     |
     v
Pods
```

In this model, the `Gateway` resource itself can represent the external traffic infrastructure.

This is one of the design goals of Gateway API: the `Gateway` resource represents an instance of traffic-handling infrastructure, while `GatewayClass` identifies the implementation/controller. citeturn0search4

This can be very attractive in managed Kubernetes because the infrastructure team can manage:

```text
GatewayClass
Gateway
```

while application teams manage:

```text
HTTPRoute
Service
Deployment
```

That separation is one of Gateway API's core role-oriented design principles. citeturn0search6

---

# 38. Pattern 3 — Bare-metal Production

If Kubernetes is running in your own data center, there may be no cloud provider to automatically create a LoadBalancer.

Then you need an external traffic mechanism such as:

```text
Physical Load Balancer
        |
        v
Kubernetes Gateway
```

or a software load-balancing implementation such as:

```text
MetalLB
    |
    v
Traefik / Gateway
```

or another approved infrastructure load balancer.

The important distinction is:

```text
Service type: LoadBalancer
```

is an API request for external load-balancing behavior.

It does not mean Kubernetes itself magically contains a physical load balancer.

The underlying environment must provide the implementation.

---

# 39. What I would change from THIS KIND lab for production

## Change #1 — Remove KIND

Production should not use:

```text
KIND
Docker Desktop
extraPortMappings
```

Instead use:

```text
EKS
AKS
GKE
OpenShift
RKE2
kubeadm
or another production Kubernetes platform
```

depending on your environment.

---

# 40. Change #2 — Remove `extraPortMappings`

Our lab has:

```yaml
extraPortMappings:

  - containerPort: 80
    hostPort: 80
    listenAddress: "127.0.0.1"

  - containerPort: 443
    hostPort: 443
    listenAddress: "127.0.0.1"
```

This is strictly a KIND/Docker Desktop mechanism.

Production does not use this.

Instead:

```text
External LB
      |
      v
Kubernetes networking
```

---

# 41. Change #3 — Remove Traefik `hostPort`

Our lab uses:

```yaml
ports:

  web:
    hostPort: 80

  websecure:
    hostPort: 443
```

For a typical cloud production deployment, I would remove these.

Instead:

```text
Traefik Pod :80/:443
        |
        v
Traefik Kubernetes Service
        |
        v
Cloud Load Balancer
```

The Pods don't need to bind directly to node ports.

This also gives the platform more flexibility when scheduling Traefik replicas across nodes.

---

# 42. Change #4 — Use multiple Traefik replicas

The lab has:

```yaml
deployment:
  kind: DaemonSet
```

because it is convenient for the KIND `hostPort` design.

For a typical cloud production setup, I would normally use:

```yaml
deployment:
  kind: Deployment
```

with multiple replicas, for example:

```yaml
replicas: 3
```

Conceptually:

```text
              Cloud Load Balancer
                 /     |     \
                /      |      \
               v       v       v
          Traefik-1 Traefik-2 Traefik-3
               \       |       /
                \      |      /
                 Gateway API
                      |
                   HTTPRoute
```

This allows Kubernetes to distribute the Gateway controller across nodes.

For high availability, don't put all replicas on the same worker node.

Use appropriate:

- topology spread constraints
- pod anti-affinity
- PodDisruptionBudget
- resource requests/limits

---

# 43. Change #5 — Production TLS

Our lab uses:

```text
self-signed certificate
```

Production should normally use a certificate issued by a trusted CA.

A common Kubernetes pattern is:

```text
cert-manager
      |
      v
ACME / Corporate CA
      |
      v
Kubernetes TLS Secret
      |
      v
Gateway
```

For example:

```text
Let's Encrypt
      |
      v
cert-manager
      |
      v
Secret
      |
      v
Gateway HTTPS listener
```

For internal corporate applications, an enterprise PKI/corporate CA may be more appropriate.

---

# 44. Change #6 — Real DNS

The lab uses:

```text
C:\Windows\System32\drivers\etc\hosts

127.0.0.1 app.chetan.local
```

Production should use real DNS:

```text
app.example.com
       |
       v
DNS
       |
       v
Load Balancer IP / hostname
```

For example:

```text
app.example.com
api.example.com
grafana.example.com
```

all resolving to the appropriate production entry point.

---

# 45. Change #7 — Production security

Our lab intentionally uses:

```yaml
runAsNonRoot: true

allowPrivilegeEscalation: false

capabilities:
  drop:
    - ALL
  add:
    - NET_BIND_SERVICE

hostNetwork: false
```

Keep the security philosophy in production.

In fact, production should go further.

Typical areas to add:

```text
Pod Security Standards
NetworkPolicy
RBAC least privilege
Secrets management
Image signing/scanning
Read-only filesystems where possible
Resource requests/limits
SecurityContext
Admission policies
Audit logging
```

Also consider restricting which namespaces/routes a Gateway controller is allowed to watch. Traefik's Gateway provider supports namespace filtering and GatewayClass label filtering. citeturn0search0

---

# 46. Change #8 — Production observability

The lab only checks:

```text
kubectl logs
curl
kubectl describe
```

Production needs:

```text
Metrics
Logs
Traces
Alerts
Dashboards
```

For example:

```text
Traefik
   |
   +--> Prometheus
   |
   +--> Grafana
   |
   +--> Central logging
   |
   +--> Distributed tracing
```

Monitor at least:

```text
Request rate
Error rate
Latency
TLS certificate expiry
Gateway availability
HTTPRoute errors
Pod availability
Load balancer health
CPU/memory
Kubernetes API errors
```

---

# 47. Change #9 — WAF / DDoS / Edge security

For a public production application, don't think of Gateway as the entire security perimeter.

A stronger architecture is:

```text
Internet
   |
   v
CDN / DDoS Protection
   |
   v
WAF
   |
   v
Cloud Load Balancer
   |
   v
Gateway Controller
   |
   v
Gateway
   |
   v
HTTPRoute
   |
   v
Service
   |
   v
Pods
```

Depending on the application and company requirements, TLS may terminate at:

```text
CDN/WAF
```

or:

```text
Gateway
```

or both, depending on the security architecture.

---

# 48. What does NOT change?

This is the most useful part.

Even in production, your application can still use:

```yaml
kind: Service

spec:
  type: ClusterIP
```

You do NOT need:

```yaml
type: NodePort
```

for every application.

You also don't need:

```yaml
type: LoadBalancer
```

for every application.

Instead:

```text
                  External entry point
                         |
                         v
                   Gateway
                         |
                         v
                    HTTPRoute
                         |
              +----------+----------+
              |          |          |
              v          v          v
           Service    Service    Service
           ClusterIP  ClusterIP  ClusterIP
              |          |          |
              v          v          v
            Pods       Pods       Pods
```

One Gateway infrastructure layer can serve many applications.

This is one of the strengths of the Gateway API model.

---

# 49. Production example

Imagine:

```text
app.example.com
api.example.com
admin.example.com
```

Instead of creating three public LoadBalancer Services:

```text
app-service       LoadBalancer
api-service       LoadBalancer
admin-service     LoadBalancer
```

you can have:

```text
                  One external entry point
                           |
                           v
                    Gateway Controller
                           |
                         Gateway
                           |
              +------------+------------+
              |            |            |
              v            v            v
         HTTPRoute    HTTPRoute    HTTPRoute
              |            |            |
              v            v            v
         app-service  api-service  admin-service
              |            |            |
              v            v            v
             Pods         Pods         Pods
```

The application Services remain:

```text
ClusterIP
```

---

# 50. Production best-practice architecture I would recommend

For a typical cloud Kubernetes environment:

```text
                         Internet
                            |
                            v
                         DNS
                            |
                            v
                    CDN / WAF / DDoS
                       protection
                            |
                            v
                 Cloud Load Balancer
                            |
                            v
              +---------------------------+
              | Kubernetes                |
              |                           |
              |  Traefik Gateway          |
              |  Controller               |
              |     x3 replicas            |
              |        |                  |
              |        v                  |
              |      Gateway              |
              |        |                  |
              |        v                  |
              |     HTTPRoute             |
              |        |                  |
              |        v                  |
              |   ClusterIP Service       |
              |        |                  |
              |    +---+---+              |
              |    |   |   |              |
              |    v   v   v              |
              |   Pod Pod Pod              |
              +---------------------------+
```

And around it:

```text
cert-manager / enterprise PKI
        |
        v
      TLS

Prometheus / Grafana
        |
        v
   Observability

NetworkPolicy
        |
        v
   East-West security

RBAC
        |
        v
   Access control

Image scanning/signing
        |
        v
   Supply-chain security
```

---

# 51. The important production decision

There are two questions:

## Question 1

> "Do I need a Load Balancer?"

### If the application must be reachable from outside the cluster:

**Yes, you need some form of external traffic entry infrastructure.**

That could be:

```text
Cloud Load Balancer
Physical Load Balancer
CDN/WAF
Reverse Proxy
External Gateway
```

It doesn't have to be Kubernetes:

```yaml
Service:
  type: LoadBalancer
```

---

## Question 2

> "Does every application Service need to be LoadBalancer?"

**No.**

Best practice is generally:

```text
External traffic
      |
      v
Gateway / Load Balancer
      |
      v
HTTPRoute
      |
      v
ClusterIP Services
      |
      v
Pods
```

not:

```text
Internet
   |
   +--> app Service LoadBalancer
   |
   +--> api Service LoadBalancer
   |
   +--> admin Service LoadBalancer
   |
   +--> monitoring Service LoadBalancer
```

The latter can create unnecessary public endpoints, cost, and security exposure.

---

# 52. Local-to-production mapping

| KIND Lab | Production |
|---|---|
| KIND | Managed/production Kubernetes |
| Docker Desktop | Cloud/bare-metal infrastructure |
| `extraPortMappings` | External LB/network integration |
| `hostPort: 80/443` | Usually removed |
| Traefik DaemonSet | Usually Deployment with multiple replicas |
| `127.0.0.1` | Public/private DNS |
| `/etc/hosts` | Corporate/public DNS |
| Self-signed TLS | Public CA / enterprise PKI |
| `curl -k` | Normal trusted TLS |
| ClusterIP Service | **Keep ClusterIP** |
| Gateway API | **Keep Gateway API** |
| GatewayClass | **Keep GatewayClass** |
| Gateway | **Keep Gateway** |
| HTTPRoute | **Keep HTTPRoute** |
| `foo-app` | Real application |
| 2 replicas | HA deployment with appropriate scaling |
| Manual logs | Centralized observability |
| Local security checks | Production security policies |

---

# 53. The key takeaway

The architecture you learned in this lab is **not thrown away in production**.

The **traffic API stays almost the same**:

```text
GatewayClass
     |
     v
Gateway
     |
     v
HTTPRoute
     |
     v
ClusterIP Service
     |
     v
Pods
```

What changes is the **infrastructure underneath the Gateway**.

### Local lab

```text
127.0.0.1
   |
KIND port mapping
   |
hostPort
   |
Traefik
```

### Production

```text
Internet
   |
DNS
   |
WAF/CDN (optional but common)
   |
Cloud/Physical Load Balancer
   |
Traefik / Gateway implementation
```

This is exactly the separation Gateway API was designed to provide: infrastructure operators manage the traffic infrastructure, while application teams can manage their routing resources such as `HTTPRoute`. citeturn0search4turn0search6

Traefik's current Gateway API implementation supports the Kubernetes Gateway API provider and its Helm chart can be configured with `providers.kubernetesGateway.enabled: true`; its provider also supports options such as namespace filtering and native Kubernetes load-balancing behavior. citeturn0search0turn0search1

---

# 54. Recommended learning progression

Now that the basic lab works, I recommend evolving it in this order:

```text
PHASE 1
KIND
  |
Traefik
  |
Gateway API
  |
HTTPRoute
  |
ClusterIP
  |
Pods
```

↓

```text
PHASE 2
Multiple HTTPRoutes
Multiple applications
Path routing
Host routing
Traffic splitting
```

↓

```text
PHASE 3
Production TLS
cert-manager
Enterprise CA / Let's Encrypt
```

↓

```text
PHASE 4
Move from KIND → real Kubernetes
```

↓

```text
PHASE 5
Traefik Deployment
3+ replicas
Cloud LoadBalancer
```

↓

```text
PHASE 6
DNS
WAF
DDoS protection
Observability
NetworkPolicy
RBAC
```

↓

```text
PHASE 7
Production HA
Multi-zone nodes
PodDisruptionBudget
Topology spread
Autoscaling
Disaster recovery
```

That progression lets you learn **the same Gateway API architecture** from laptop → staging → production rather than learning one completely different architecture for each environment.

---

# 55. One final production rule

Do not think:

```text
"I need a LoadBalancer Service because I'm using Gateway API."
```

Think:

```text
"I need a reliable external entry point for my Gateway."
```

Then choose the appropriate implementation:

```text
Cloud LB
Physical LB
CDN/WAF
Gateway controller integration
LoadBalancer Service
External reverse proxy
```

based on your infrastructure.

The **Gateway API layer remains the routing abstraction**.

The **load-balancing implementation is infrastructure-dependent**.
