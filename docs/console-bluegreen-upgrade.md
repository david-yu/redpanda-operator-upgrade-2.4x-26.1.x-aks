# Console v2 → v3 zero-downtime upgrade — blue/green pattern

The operator's chart-based reconciliation **cannot** roll Console from v2.x →
v3.x in place. Validated 2026-05-01 across four sub-tests on AKS:

| Sub-test | Action taken | Result |
| -------- | ------------ | :----: |
| A | Drop `chartRef.chartVersion` from CR, keep explicit `console.image.tag: v2.8.0` | Console stayed v2.8.0 (expected — pin retained) |
| B | Also drop the explicit `console.image` block from CR | **Console stayed v2.8.0** — operator did not roll the pod |
| C | Delete the `redpanda-console` Deployment to force re-render | Operator recreated it at v2.8.0 again |
| D | Bump a reconcile annotation on the Redpanda CR | No change to Console image |

Helm-template static analysis confirms chart 25.1.x's default Console
image is v3.1.0 *if no override is supplied*; the operator nevertheless
keeps re-applying v2.8.0 from a cached Helm release values block.

**Conclusion:** for the customer's upgrade, treat Console v2 → v3 as a
parallel deployment plus a Service / Ingress cutover, not as an
operator-managed in-place roll. Same validation also showed the cutover
itself is zero-downtime when done as a wholesale Service-selector swap.

## The pattern

```
    ┌─────────────────────────────────────────────────────────────┐
    │  before: ingress / active-service ───►  Console v2 (chart) │
    │                                                              │
    │  step 1: deploy parallel Console v3 with own Service        │
    │                       ───►  Console v2 (chart)              │
    │                       └─►  Console v3 (standalone) [warm]   │
    │                                                              │
    │  step 2: wholesale-replace active selector v2 → v3 (~1 s)    │
    │                       ───►  Console v3 (standalone)         │
    │                                                              │
    │  step 3: disable Console subchart (CR.console.enabled=false)│
    │           operator removes v2 Deployment                    │
    │                       ───►  Console v3 (standalone) [final] │
    └─────────────────────────────────────────────────────────────┘
```

## Validated steps (2026-05-01, fresh AKS)

### Step 1. Deploy standalone v3 alongside the operator-managed v2

```yaml
# console-v3.yaml — drop into the customer's git repo for ArgoCD sync
apiVersion: v1
kind: ConfigMap
metadata: {name: redpanda-console-v3, namespace: redpanda}
data:
  config.yaml: |
    metricsNamespace: console
    serveFrontend: true
    server: { gracefulShutdownTimeout: 30s, listenPort: 8080 }
    kafka:
      brokers:
        - redpanda-0.redpanda.redpanda.svc.cluster.local:9092
        - redpanda-1.redpanda.redpanda.svc.cluster.local:9092
        - redpanda-2.redpanda.redpanda.svc.cluster.local:9092
    schemaRegistry:
      enabled: true
      urls: [http://redpanda-0.redpanda.redpanda.svc.cluster.local:8081]
    redpanda:
      adminApi:
        enabled: true
        urls: [http://redpanda-0.redpanda.redpanda.svc.cluster.local:9644]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redpanda-console-v3
  namespace: redpanda
  labels: {app.kubernetes.io/name: console, console-version: v3}
spec:
  replicas: 1                        # bump to 2 in production for HA
  selector: {matchLabels: {console-version: v3}}
  template:
    metadata:
      labels: {app.kubernetes.io/name: console, console-version: v3}
    spec:
      containers:
        - name: console
          image: docker.redpanda.com/redpandadata/console:v3.7.0
          args: [-config.filepath=/etc/console/config.yaml]
          ports: [{name: http, containerPort: 8080}]
          volumeMounts: [{name: cfg, mountPath: /etc/console}]
          readinessProbe:
            httpGet: {path: /admin/health, port: 8080}
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /admin/health, port: 8080}
            initialDelaySeconds: 30
            periodSeconds: 10
      volumes:
        - name: cfg
          configMap: {name: redpanda-console-v3}
---
apiVersion: v1
kind: Service
metadata: {name: redpanda-console-v3, namespace: redpanda}
spec:
  type: ClusterIP
  selector: {console-version: v3}
  ports: [{name: http, port: 8080, targetPort: 8080}]
```

Verify v3 is healthy before proceeding:

```bash
kubectl -n redpanda rollout status deploy/redpanda-console-v3 --timeout=2m
kubectl -n redpanda run --rm -it --image=curlimages/curl curl-test -- \
  curl -sS http://redpanda-console-v3:8080/admin/health
```

### Step 2. Cutover the active selector — wholesale replace

This is the moment of truth. Use **`kubectl apply`** (or ArgoCD wholesale
sync), **not `kubectl patch --type=merge`** — merge keeps the prior
selector keys and breaks endpoint matching. We saw this in the
validation: a merge patch left `app.kubernetes.io/instance: redpanda` in
the selector and the v3 pod (which doesn't have that label) was orphaned
from the Service for the duration.

```yaml
# active-service.yaml — flip this block in git
apiVersion: v1
kind: Service
metadata:
  name: redpanda-console-active
  namespace: redpanda
  annotations:
    upgrade.redpanda.com/active: v3                   # before: v2
spec:
  type: ClusterIP
  selector:
    console-version: v3                                # before:
                                                       #   app.kubernetes.io/instance: redpanda
                                                       #   app.kubernetes.io/name: console
  ports: [{name: http, port: 8080, targetPort: 8080}]
```

Apply with `kubectl apply` (replaces full spec, not merge):

```bash
kubectl apply -f active-service.yaml
```

Endpoint slice typically refreshes in **< 2 seconds**. Validation timing
on a 3-node AKS cluster:

```
T_CUTOVER:        17:35:31.3Z   (kubectl apply called)
T_APPLIED:        17:35:32.3Z   (apiserver acknowledged)
T_ENDPOINT_FLIP:  17:35:33.3Z   (endpoint slice now points at v3 pod IP)
```

A 4 Hz HTTP probe (every 250 ms) against the active Service URL across
the cutover window saw **0 failures**:

```
2026-05-01T17:35:23  http=200 ok=100  fail=0   (last baseline snapshot)
2026-05-01T17:35:31  CUTOVER
2026-05-01T17:35:37  http=200 ok=150  fail=0
2026-05-01T17:35:51  http=200 ok=200  fail=0
2026-05-01T17:36:05  http=200 ok=250  fail=0
... probe ran for another 5 min, total 550 OK / 0 fail ...
```

The same applies to an actual `Ingress` resource — patching the
`spec.rules[].http.paths[].backend.service.name` from `redpanda-console`
to `redpanda-console-v3` (or wholesale-replacing the Ingress) gives the
same flip semantics. Pick the route that matches your customer's existing
ingress controller (nginx, AGIC, traefik) — the cutover behavior is
identical.

### Step 3. Remove operator-managed v2

Once the cutover is verified, disable the chart's Console subchart in the
Redpanda CR:

```yaml
spec:
  clusterSpec:
    console:
      enabled: false
```

The operator removes the `redpanda-console` Deployment + Service +
ConfigMap on the next reconcile. Validation showed this completes in
< 60 s and the active Service is unaffected.

### Step 4. (Optional) Rename the standalone deployment back

If you want `redpanda-console` as the canonical name post-cutover, rename
the standalone deployment + service from `-v3` back to `redpanda-console`
in a follow-up commit. ArgoCD will create the new resources and prune the
`-v3` ones. The active Service selector flips one more time (4 → final).
This is cosmetic; you can also keep `-v3` indefinitely.

### Step 5. (Required end-state, operator 26.1+) Bring Console back under operator management

The blue/green cutover deliberately moves Console **out** of operator
management for the upgrade window. **The required end-state, once
operator 26.1+ is in place, is to put Console back under operator
management** by applying a `Console` CR — the operator-native way to
declare a Console instance separately from the Redpanda CR. This is a
separate top-level resource (`cluster.redpanda.com/v1alpha2`,
`kind: Console`), in the `stableCRDs` list installed by the chart's
pre-install Job whenever `crds.enabled: true`. The `ConsoleReconciler`
is on by default (operator flag `--enable-console=true`).

**Why this is part of the upgrade, not an optional polish step:** the
Redpanda chart's bundled `console:` subchart is legacy. Going forward,
Console is a separate top-level CR. Operator chart bumps in the 26.x →
27.x line will assume Console is expressed via the CRD; leaving Console
as a hand-rolled standalone Deployment means every future operator
bump requires a separate manual step to keep Console image versions
current.

**Why this is itself a blue/green:** the Console CR's reconciler creates
its own Deployment (named `redpanda-console`). It does **not** adopt the
existing standalone Deployment. So the same wholesale-replace
Service-selector pattern applies — flip the active Service from the
standalone v3 to the operator-managed v3, then delete the standalone
manifests.

```yaml
# manifests/console-cr.yaml — drop into git, ArgoCD applies it
apiVersion: cluster.redpanda.com/v1alpha2
kind: Console
metadata:
  name: redpanda-console
  namespace: redpanda
spec:
  cluster:
    clusterRef:
      name: redpanda                       # Redpanda CR's name
  replicaCount: 1
  podLabels:
    console-version: managed-v3            # used by the active Service
  service:
    type: ClusterIP
    targetPort: 8080
  # ConsoleValues is "PartialValues" of the upstream console chart, so
  # any field not set falls through to the chart's defaults. The most
  # commonly customised piece is config (the equivalent of console.yaml).
  # See operator/api/redpanda/v1alpha2/console_types.go for the full schema.
  config:
    kafka:
      brokers:
        - redpanda-0.redpanda.redpanda.svc.cluster.local:9092
        - redpanda-1.redpanda.redpanda.svc.cluster.local:9092
        - redpanda-2.redpanda.redpanda.svc.cluster.local:9092
    schemaRegistry:
      enabled: true
      urls: [http://redpanda-0.redpanda.redpanda.svc.cluster.local:8081]
    redpanda:
      adminApi:
        enabled: true
        urls: [http://redpanda-0.redpanda.redpanda.svc.cluster.local:9644]
```

**Cutover steps** (same probe-protected wholesale-replace as Step 2):

```bash
# 1. Apply the Console CR; wait for the operator-managed pod to be Ready.
kubectl apply -f manifests/console-cr.yaml
kubectl -n redpanda wait --for=condition=Ready --timeout=2m \
  pod -l console-version=managed-v3

# 2. Flip the active Service selector — wholesale apply, NOT merge.
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: redpanda-console-active
  namespace: redpanda
  annotations: { upgrade.redpanda.com/active: managed-v3 }
spec:
  type: ClusterIP
  selector: { console-version: managed-v3 }
  ports: [{ name: http, port: 8080, targetPort: 8080 }]
YAML

# 3. Verify probe is clean, then delete the standalone v3 manifests.
kubectl delete deploy redpanda-console-v3 svc redpanda-console-v3 cm redpanda-console-v3
```

**Operator-managed advantages once flipped:**
- Console version follows the operator chart's appVersion automatically
  on each operator bump (no manual image pin).
- `kubectl get console redpanda-console` shows reconcile status,
  observedGeneration, and replica counts directly.
- Single ArgoCD Application for the Redpanda CR + Console CR; no
  separate "standalone Console" tree to maintain.

**Operational notes:**
- Land all of Step 5's manifests (Console CR + active-Service flip +
  removal of the standalone Deployment / ConfigMap / Service) in the
  **same git commit**. Splitting them lets ArgoCD and the operator
  briefly fight over Deployment ownership.
- A short soak between Phase 5 and Step 5 is fine if the customer wants
  to observe a steady state, but Step 5 is part of the upgrade — not a
  follow-up to be skipped indefinitely.
- The Console CR's schema is `ConsoleValues` (PartialValues of the
  upstream chart). Common knobs (`replicaCount`, `image`, `service`,
  `ingress`, `config`, `resources`, ...) are exposed; very niche values
  may not be expressible yet — see
  `operator/api/redpanda/v1alpha2/console_types.go` for the canonical
  struct, and file an upstream issue if your customer needs a missing
  field.

## What this pattern relies on

- **Both deployments share the upstream Redpanda cluster.** Console is
  stateless — it reads from Kafka, Schema Registry, and the Admin API.
  Two parallel Console pods don't interfere with each other.
- **Service-selector flips are O(seconds).** Endpoint slice propagation
  on AKS / Azure CNI was < 2 s in validation. kube-proxy on each node
  picks up the change without packet drops on existing in-flight TCP
  connections; new connections route to the new endpoint.
- **HTTP-only access pattern.** Console is mostly HTTP REST + WebSocket.
  Long-lived WebSockets get reset across the cutover (the client
  reconnects within a few hundred ms); HTTP request/response is
  unaffected.

## Gotchas

- **Don't `kubectl patch --type=merge` the Service selector.** Use
  `apply` (or ArgoCD's normal sync). Merge leaves prior keys in the
  selector and the new pod is orphaned. We hit this exact failure in
  the validation (took 5 min to spot).
- **Auth: if the v2 Console used SSO (OIDC), the v3 schema for
  `authentication.providers[]` is different.** Have the v3 ConfigMap
  ready with the new schema before the cutover; see
  [`docs/console-v2-to-v3.md`](console-v2-to-v3.md) for the field map.
- **Persistent state**: Console doesn't have any (no PVCs, no DB),
  so blue/green has no data-migration step. Confirmed.
