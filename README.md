# Redpanda Operator upgrade — v2.4.x → 26.1.x on AKS, ArgoCD-managed

Step-by-step runbook for upgrading a customer cluster from
**Operator binary v2.4.x / Redpanda chart 5.10.x / Redpanda 25.1.9** to
**Operator binary 26.1.x / Redpanda chart 26.1.x / Redpanda 26.1.x**, with no
broker downtime, on AKS, with everything declared via ArgoCD `Application`
manifests, and the upgrade probed end-to-end by an OpenMessaging Benchmark
worker driving ~10 MB/s on a separate VM.

> **Plan review status:** the customer's proposed phasing
> ([Phase 0a → Phase 5 below](#upgrade-phases)) is **sound**, with three
> caveats called out inline (bootstrap-user secret, `useFlux` migration,
> CRD ordering for ArgoCD). See [Plan review](#plan-review) for the
> annotated version.

---

## Repo layout

```
applications/      ArgoCD Application manifests — one per phase
values/            Helm values overlays per operator/Redpanda chart version
manifests/         Raw k8s manifests (Redpanda CR, namespaces, Console add-on)
probes/            OMB driver + workload + VM bootstrap
docs/              Per-topic deep-dives (ArgoCD ordering, Console v2→v3, rollback)
```

Apply order is **strictly sequential**: every phase ends with a green
verification gate before the next phase's `git push` lands in the
ArgoCD-watched branch.

---

## Plan review

The customer's plan is reproduced below with **inline notes** (`📌 NOTE`,
`⚠️ CONCERN`, `✅ OK`). Where the customer asked a clarifying question
(`?`), the answer is in‑line.

### Source

- Redpanda: `25.1.9` ✅
- Operator binary: `v2.4.x` ✅ (assuming `v2.4.6`, the latest in that line)
- Operator chart: `2.4.x` ✅ — the chart at the v2.4.x tag is named
  `operator` and pinned at chart version `2.4.6`/`appVersion v2.4.6`
  (verified against `operator/v2.4.6` git tag). It is the **same chart
  name** as the 25.x+ release line, so Phase 0a is a normal `helm upgrade`
  (NOT a chart rename) — earlier drafts of this README incorrectly claimed
  a rename. **Caveat for the customer's specific setup:** chart versions
  before `25.2.3` are no longer published to `https://charts.redpanda.com`.
  If you previously installed `operator-2.4.6` from that repo, the
  Application's `spec.source.targetRevision: 2.4.6` will fail to fetch
  during a fresh sync. The chart can be reconstructed from the
  `operator/v2.4.6` git tag if needed for a re-install (highly unusual —
  the running release is unaffected).
- Redpanda chart: `5.10.x` ✅
- Tiered storage: none ✅

### Target

- Redpanda: `26.1.x` ✅
- Operator binary + chart: `26.1.x` ✅
- Redpanda chart: `26.1.x` ✅

### Upgrade phases

| Phase | What changes | Broker restart? | Validated downtime (Run 3) |
| ----- | ------------ | :-------------: | :-------------------: |
| 0a    | Operator binary + chart `v2.4.x → 25.1.x`, CRDs reapplied | no | 0 errors |
| 0b    | (a) drop `chartRef.chartVersion` from CR (operator embeds chart now), (b) **Console v2 → v3 blue/green cutover** (deploy v3 standalone, flip active Service, then `console.enabled: false`), (c) `useFlux: false`. Triggers an incidental broker rolling restart from chart 5.10 → 25.1 pod-spec drift. | yes (incidental) | 0 errors (cutover ~2 s) |
| 1     | Redpanda broker `25.1.9 → 25.2.x` (chart bump is implicit — operator pins it via embedded chart, see [Delta #1](#deltas-id-recommend-on-top-of-the-customers-plan)) | yes (rolling) | 0 errors |
| 2     | Operator binary + chart `25.1.x → 25.3.x` (skips 25.2 — both 25.1 and 25.3 manage 25.2 brokers) | no | 0 errors |
| 3     | Redpanda broker `25.2.x → 25.3.x` (chart bump implicit) | yes (rolling) | 0 errors |
| 4     | Operator binary + chart `25.3.x → 26.1.x` | no | 0 errors |
| 5     | Redpanda broker `25.3.x → 26.1.x` (chart bump implicit). AKS K8s ≥ 1.32 required. | yes (rolling) | 0 errors |

**Required follow-up step (slots in right after Phase 2):**

| Phase | What changes | Broker restart? | Validated downtime (Run 3) |
| ----- | ------------ | :-------------: | :-----------------------: |
| **2b**    | Bring Console v3 back under operator management via the new `cluster.redpanda.com/v1alpha2 Console` CRD. The CRD ships in operator **25.2+** (verified in `operator/v25.2.4` source — `crds.Console()` is in `stableCRDs`); since Phase 2 lands the operator on 25.3.x, the CRD is available immediately afterwards. **Required end-state** so future operator bumps continue to manage Console — the Redpanda chart's bundled `console:` subchart is the legacy mechanism. | no (Console-only flip ~2 s) | 0 errors |

**Total validated upgrade window** (Run 3, 3-broker AKS cluster on
Standard_D4s_v3): ~20 minutes wall clock for source state → terminal
state through Phase 5, with `kafka-probe` recording **158,000 produces /
0 errors** and `console-probe` recording **4,700 HTTP 200 / 0 failures**
across the entire run. Phase 2b adds another ~30 s for the Console
managed-Deployment to come up + the Service-selector flip; uses the
same probe machinery.

### Customer's open questions

| Q | A |
| - | - |
| Phase 0b: Helm Chart `5.10.x → 25.1.x` (reconciled by Operator)? | **Yes.** With `spec.chartRef.useFlux: false`, the operator drives the chart upgrade in-process via `lifecycle.SyncAll`. With `useFlux: true`, the in-cluster Flux HelmRelease reconciles. Phase 0a should leave `useFlux` whatever it is today; phase 0b is where you'd flip to fluxless if desired (recommended — Flux dependency removed in operator 25.x+ for v2 controllers). |
| Phase 0b: Console v2 → v3 side effect — review migration guide first? | **Yes, but the chart-driven side-effect doesn't work.** Validated empirically (Run 1, Run 2, Run 3): the operator can't roll Console v2 → v3 in place when the chart bumps. The supported path is a **blue/green cutover in Phase 0b** (deploy standalone Console v3, flip an active Service, disable the chart's bundled Console) followed by **Phase 2b** (adopt the new `Console` CRD once the operator is on 25.2+). See [`docs/console-bluegreen-upgrade.md`](docs/console-bluegreen-upgrade.md) for the manifests + cutover timing, and [`docs/console-v2-to-v3.md`](docs/console-v2-to-v3.md) for the v3 config schema. |
| Phase 1: HTTP Proxy auth breaking change? | **Skip the workaround — customer is not running HTTP Proxy.** Confirmed `pandaproxy.enabled: false` in the customer's values. The breaking change is irrelevant. |
| Phase 3: Iceberg schema + topic retention? | **Skip — customer has no Iceberg topics.** No action. |
| Phase 5: K8s ≥ 1.32? | **AKS upgrade required first** if the cluster is on `<1.32`. AKS supports 1.32 GA across all regions. Document the AKS upgrade as Phase −1 (pre-flight) below. |

### Deltas I'd recommend on top of the customer's plan

1. **🚨 `spec.chartRef.chartVersion` is rejected by operator 25.1+.** Validated end-to-end (see [`VALIDATION-RESULTS.md`](VALIDATION-RESULTS.md), 2026-05-01). Setting an explicit `chartRef.chartVersion` produces *"Specifying chartVersion is no longer supported. Please downgrade or unset `chartRef.chartVersion`"* on every reconcile and the CR stops progressing. The operator now **embeds** its chart — operator binary version pins the chart version. The customer's plan should: (a) remove `chartRef.chartVersion` from every CR before Phase 0a (operator v2.4.x still accepts it but deprecates it), (b) treat each operator bump as a chart bump too — Phase 1's "chart 25.1.x → 25.2.x" is no longer a separate action, it happens automatically when Phase 2 bumps the operator. The phase table below has been updated accordingly.

2. **Add a Phase −1 pre-flight** that captures (a) cluster spec + Redpanda CR + Console deployment as a known-good snapshot for rollback, (b) confirms AKS `>=1.32` (required for Phase 5), (c) records broker IDs / disk sizes / partition counts as a "before" baseline.

3. **🚨 Hard prerequisite for Phase 2: `spec.chartRef.useFlux: false` on every Redpanda CR.** This is **not optional** and is the single most important addition to the customer's plan. **Operator 25.2.x removed Flux entirely** ([release notes](https://docs.redpanda.com/25.1/get-started/release-notes/operator/#flux-removed)). The 25.2.x reconciler explicitly skips any `Redpanda` whose `spec.chartRef.useFlux` is `true` (verified in source: `operator/internal/controller/redpanda/redpanda_controller.go` ~line 937 — *"Don't reconcile if UseFlux is true"*), so the CR silently falls out of management after the Phase 2 operator bump. Make the `useFlux: false` flip part of **Phase 0a or Phase 0b** and add a verification gate before Phase 2 (see [`docs/flux-removal.md`](docs/flux-removal.md)). For the customer's actual environment (running operator v2.4.x today, where Flux is the legacy default), this is the migration step the upgrade plan was missing.

4. **Skip operator `25.2.x` is fine** — both `25.1.x` and `25.3.x` operators support clusters running `25.2.x`. The customer's "25.1 → 25.3" jump is supported (validated, ~97 s, zero produce errors).

5. **🚨 Console v2 → v3 cannot be rolled in place by the operator.** Validated (Runs 1–3): even with `chartRef.chartVersion` dropped, an explicit `console.image` block removed, the Deployment deleted to force re-render, or a reconcile annotation bumped — the operator keeps re-applying Console v2.8.0 from a cached Helm release values block. **The supported path is a blue/green cutover in Phase 0b** (deploy a standalone Console v3 alongside, flip a `redpanda-console-active` Service to v3 wholesale, set `console.enabled: false` on the Redpanda CR), followed by **Phase 2b** once the operator is past 25.2.x — at which point apply a `cluster.redpanda.com/v1alpha2 Console` CR and a second wholesale-replace of the active Service to bring Console under operator management via the new CRD. Both cutovers were measured at ~2 s with zero dropped probes (Run 3: 4,700 HTTP / 0 fails). Manifests in [`docs/console-bluegreen-upgrade.md`](docs/console-bluegreen-upgrade.md). The earlier README draft suggested "ArgoCD wholesale replace fixes the in-place upgrade" — that claim was wrong and has been removed.

6. **🚨 Phase 2b — adopt the `Console` CRD as the upgrade's Console end-state.** The Redpanda chart's bundled `console:` subchart is the legacy mechanism. Operator 25.2+ ships a separate top-level `cluster.redpanda.com/v1alpha2 Console` CRD ([release notes](https://docs.redpanda.com/25.2/get-started/release-notes/operator/), verified in `operator/v25.2.4` source). Going forward, Console is expressed via that CR; future operator bumps assume it. Phase 2b runs immediately after Phase 2 (operator 25.3.4) and is **required**, not optional — leaving Console as a hand-rolled standalone Deployment means every future operator bump needs a separate manual step to keep the Console image current.

7. **OMB rate of 10 MB/s** is comfortably within the smallest reasonable AKS-hosted Redpanda cluster (3 × Standard_D4s_v3 + premium SSD). Running OMB on a 4 vCPU VM with default driver settings produces ≈100 k msg/s at 1 KB; the workload here caps at 10 k msg/s for headroom.

8. **PDB tightness during Phase 1/3/5**: confirm `clusterSpec.statefulset.podDisruptionBudget.maxUnavailable: 1` and that replicas ≥ 3 with replication-factor ≥ 3 on production topics; otherwise rolling restarts can take a partition offline briefly. (Validation saw clean rolling restarts on a 3-broker cluster with `replication.factor=3` and `min.insync.replicas=2`.)

9. **🚨 `syncOptions: ServerSideApply=true` is required on every ArgoCD `Application` for the upgrade.** The chart-5.10 → chart-25.3 jump in Phase 2 swaps the broker `livenessProbe` handler from `exec` (curl-based) to `tcpSocket`. Client-side strategic merge (`kubectl apply` / `helm upgrade` without `--force`) keeps both handlers, and K8s rejects the resulting pod spec (*"may not specify more than 1 handler type"*) — leaving Phase 3 unable to recreate `redpanda-0`. Validated in Run 4 (see [`VALIDATION-RESULTS.md`](VALIDATION-RESULTS.md)). Server-side apply tracks per-field ownership and replaces the field cleanly, so this is a non-issue under ArgoCD as configured ([`applications/`](applications/) already specifies `ServerSideApply=true`). If anyone reproduces the upgrade with `helm upgrade` directly outside of ArgoCD, pass `--force` for the chart bumps that span major chart versions.

---

## Pre-flight (Phase −1)

```bash
# Snapshot
kubectl -n redpanda get redpanda <name> -o yaml > snapshots/redpanda-cr.yaml
kubectl -n redpanda get cm,secret,sts,svc,pdb -o yaml > snapshots/k8s-state.yaml
kubectl -n redpanda-system get deploy redpanda-operator -o yaml > snapshots/operator-deploy.yaml
helm -n redpanda-system list -o json > snapshots/helm-releases.json

# Confirm AKS >= 1.32 (Phase 5 prerequisite)
az aks show -g <rg> -n <aks> --query 'kubernetesVersion' -o tsv
# If lower:
az aks upgrade -g <rg> -n <aks> --kubernetes-version 1.32.X --yes
# (Bumps control plane + nodepools; this itself is rolling and OMB-safe.)

# Baseline broker state
kubectl -n redpanda exec <broker-0> -c redpanda -- rpk cluster info
kubectl -n redpanda exec <broker-0> -c redpanda -- rpk cluster health -w 0s
```

Bring up the OMB VM and start the steady-state workload **before** Phase 0a
begins. Detailed steps in [`probes/`](probes/README.md).

---

## ArgoCD model

Two long-lived ArgoCD `Application`s manage everything:

- `redpanda-operator` → tracks the operator chart (`operator/`) at the
  version pinned for the current phase.
- `redpanda-cluster` → tracks `manifests/redpanda-cluster.yaml`
  (the `Redpanda` CR + namespace + auxiliary Secrets).

Each phase = **one git commit** that changes the `targetRevision` + values
file pointer for one of those Applications. ArgoCD's auto-sync rolls the
change. Each phase is protected by:

- `syncPolicy.automated.prune: false` for the whole upgrade window
  (prevents accidental destruction during chart shape changes),
- `syncOptions: [ServerSideApply=true, RespectIgnoreDifferences=true]`,
- `ignoreDifferences` for fields the operator owns (replicas counts,
  status).

Skeleton `Application`s live in [`applications/`](applications/). Each phase
file shows exactly what's bumped from the previous phase.

---

## Phases

Each section links to the manifest diff and lists exit criteria. All
`kubectl get` commands assume `KUBECONFIG` points at the AKS cluster.

### Phase 0a — Operator binary v2.4.x → 25.1.x

**ArgoCD change:** [`applications/phase-0a-operator-25.1.yaml`](applications/phase-0a-operator-25.1.yaml)

```yaml
spec:
  source:
    chart: operator                      # NEW chart name (was redpanda-operator)
    repoURL: https://charts.redpanda.com
    targetRevision: 25.1.3               # latest 25.1 patch
    helm:
      valueFiles: [values/operator-25.1.yaml]
```

**Notes:**
- The chart **rename** (`redpanda-operator` → `operator`) means the
  Application's `spec.source.chart` field changes. ArgoCD treats the new
  Application as a fresh release; you must `argocd app sync redpanda-operator
  --replace` after the commit so it deletes the old release and installs
  the new one. The CRDs survive this delete (cluster-scoped, not in any
  namespace).
- `crds.enabled: true` in [`values/operator-25.1.yaml`](values/operator-25.1.yaml)
  installs CRDs via the chart's pre-install Job.
- No broker restart.

**Exit criteria:**
- `kubectl -n redpanda-operator get pods` → all `Running`, image tag
  `v25.1.3`.
- `kubectl get crds | grep redpanda.com` → all CRDs are at the new schema
  versions (controller-gen embeds version in the CRD's `annotations`).
- OMB throughput unaffected.

### Phase 0b — chart 5.10 → embedded 25.1 + Console **blue/green** cutover

**This phase is the most complex of the upgrade.** Three changes land in
one git commit:

1. **Drop `spec.chartRef.chartVersion`** from the Redpanda CR. Operator
   25.1+ rejects an explicit `chartVersion`; the operator binary now
   embeds its own chart and pins the version to its own release.
2. **Cut over the Console "active" Service from v2 (operator-managed) to
   v3 (standalone)** — see the blue/green steps below.
3. **Set `spec.clusterSpec.console.enabled: false`** so the operator GCs
   the now-orphaned v2 Console Deployment.

**ArgoCD change:** [`applications/phase-0b-redpanda-cluster.yaml`](applications/phase-0b-redpanda-cluster.yaml)

#### High-level: Console v2 → v3 blue/green

The operator **cannot** roll Console v2 → v3 in place — verified
across four sub-tests (drop the explicit image pin, delete the
Deployment to force re-render, bump a reconcile annotation, etc. — full
matrix in [`VALIDATION-RESULTS.md`](VALIDATION-RESULTS.md)). The chart's
default Console image is correct (v3.7.x) but the operator's reconcile
keeps re-applying v2.8.0 from a cached Helm release values block. The
working pattern is a **blue/green** swap: stand up Console v3 alongside
the operator-managed v2, flip an "active" Service that the
ingress / clients point at, then disable the operator's Console.

```
   ┌──────────────────────────────────────────────────────────────┐
   │  before:  ingress / app clients ──►  redpanda-console-active │
   │                                          (selector → v2)     │
   │                                                               │
   │  step 1:  deploy parallel Console v3 + its own Service        │
   │           ──►  operator-managed Console v2  [active]          │
   │           ──►  standalone Console v3        [warm, idle]      │
   │                                                               │
   │  step 2:  kubectl apply the active Service spec wholesale     │
   │           — selector switches to {console-version: v3}        │
   │           ──►  operator-managed Console v2  [idle]            │
   │           ──►  standalone Console v3        [active]          │
   │                                                               │
   │  step 3:  CR.console.enabled=false                            │
   │           operator GCs the v2 Deployment + Service + CM       │
   │           ──►  standalone Console v3        [active, sole]    │
   └──────────────────────────────────────────────────────────────┘
```

**Steps in this phase's git commit (all land together in one push).**
Walk through [`docs/console-bluegreen-upgrade.md`](docs/console-bluegreen-upgrade.md)
Steps 1–3 for the full validated procedure; the manifests this phase
adds are checked in:

1. **Add v3 manifests** —
   [`manifests/console-v3-standalone.yaml`](manifests/console-v3-standalone.yaml)
   (ConfigMap + Deployment + Service for the standalone v3). Adjust
   the embedded `config.yaml` if your customer's Kafka /
   Schema-Registry / Admin-API URLs differ from the validated default.
2. **Add the `redpanda-console-active` Service** —
   [`manifests/console-active-service.yaml`](manifests/console-active-service.yaml).
   The committed file has the **final** Phase-2b state
   (`selector: console-version: managed-v3`); for Phase 0b, edit the
   selector to `console-version: v3` and apply (`kubectl apply -f` —
   never `kubectl patch --type=merge`, which leaves prior selector
   keys behind).
3. **Update the Redpanda CR** to (a) drop `chartRef.chartVersion`, (b)
   keep `useFlux: false`, (c) set `console.enabled: false`.

The Service-selector flip propagates in **~2 s** (Endpoint slice
reconcile). HTTP requests in flight at the moment of the flip complete
against the v2 backend; new requests route to v3. Validated in
[Run 3](VALIDATION-RESULTS.md#run-3--full-upgrade-with-console-bluegreen):
**4,700 HTTP probes / 0 failures** across the entire upgrade window
including the cutover.

```yaml
# Redpanda CR diff for Phase 0b
spec:
  chartRef:
    chartName: redpanda
    # chartVersion: 25.1.4   ← REMOVED — operator embeds chart now
    helmRepositoryName: redpanda-repository
    useFlux: false           # MIGRATE off Flux during this phase
  clusterSpec:
    image:
      tag: v25.1.9           # NO broker version bump in this phase
    console:
      enabled: false         # operator GCs v2 Console — v3 standalone takes over
```

**Notes:**
- The `chartRef.chartVersion` removal is mandatory in operator 25.1+;
  see Delta #1 under [Plan review](#deltas-id-recommend-on-top-of-the-customers-plan).
- Even though `console.enabled` is set to `false`, the actual Console UI
  stays available — traffic flows through the standalone v3 Deployment
  via the active Service. Validated in Run 3.
- The chart-shape change (5.10 → 25.1) triggers an **incidental rolling
  broker restart** as the operator re-renders the StatefulSet pod spec.
  In Run 3 this was clean — `kafka-probe` showed 0 errors across the
  ordinal-by-ordinal restart with `pdb.maxUnavailable: 1` and
  `replication.factor: 3`.

**Exit criteria:**
- `kubectl get pods -l app.kubernetes.io/name=console -n redpanda` →
  only `redpanda-console-v3-…` Running. The operator-managed
  `redpanda-console-…` pod is gone.
- `kubectl get svc redpanda-console-active -n redpanda \
   -o jsonpath='{.spec.selector}'` → `{ console-version: v3 }`.
- Console UI smoke test through the ingress / active Service returns
  200 on `/admin/health` and renders the v3 SPA on `/`.
- All Redpanda broker pods Ready, `rpk cluster health` Healthy=True.
- Old `HelmRelease`/`HelmRepository` CRs (from Flux) GC'd by the operator.
- Continuous probes (Kafka producer + HTTP) show zero failures across
  the cutover window.

### Phase 1 — Redpanda broker 25.1.9 → 25.2.x

**ArgoCD change:** [`applications/phase-1-redpanda-25.2.yaml`](applications/phase-1-redpanda-25.2.yaml)

```yaml
spec:
  chartRef: { chartVersion: 25.2.5, ... }
  clusterSpec:
    image: { tag: v25.2.4 }
```

**Rolling broker restart** triggered by the chart upgrade. The operator
walks the StatefulSet ordinals one at a time, draining + waiting for each
broker to rejoin the ISR before continuing.

**Exit criteria:**
- `rpk cluster health` returns `Healthy: true` after each broker is
  recycled.
- `kubectl get pods -n redpanda` shows all brokers Running with new image.
- OMB shows zero error rate; latency p99 stays within target.

### Phase 2 — Operator 25.1.x → 25.3.x

**ArgoCD change:** [`applications/phase-2-operator-25.3.yaml`](applications/phase-2-operator-25.3.yaml).

Same shape as Phase 0a, just bumps `targetRevision` and the values file.
**Operator skip from 25.1 → 25.3** (skipping 25.2 binary) is supported —
both 25.1 and 25.3 manage 25.2 brokers. No broker restart.

### Phase 2b — bring Console v3 back under operator management via the new `Console` CRD

After Phase 2, the operator is on **25.3.4** — and the Console CRD
(`cluster.redpanda.com/v1alpha2`, `kind: Console`) is now installed by
the chart's pre-install Job. The CRD was [introduced in operator
25.2.x](https://docs.redpanda.com/25.2/get-started/release-notes/operator/);
verified against `operator/v25.2.4` source — `crds.Console()` is in the
`stableCRDs` list.

**Phase 2b moves Console back under operator management** by adopting
the CRD. This is a **required** part of the upgrade — the Redpanda
chart's bundled `console:` subchart is the legacy mechanism. Going
forward:

- Console is a separate top-level resource managed by the operator's
  `ConsoleReconciler` (enabled by default via `--enable-console=true`).
- Operator chart bumps in the 26.x → 27.x line will assume Console is a
  `Console` CR. Leaving Console as a hand-rolled standalone Deployment
  means every future operator bump requires a separate manual step to
  keep Console image versions current.
- Declarative parity with the rest of the cluster: `kubectl get console`
  alongside `kubectl get redpanda`.

**The flip is itself a blue/green cutover** — same pattern as Phase 0b,
just in reverse:

```
   ┌──────────────────────────────────────────────────────────────┐
   │  before:  ingress ──►  redpanda-console-active                │
   │                          (selector → standalone v3)           │
   │                                                                │
   │  step 1:  apply a Console CR alongside the standalone v3      │
   │           operator creates redpanda-console-managed v3        │
   │           pod with its own Service                            │
   │                                                                │
   │  step 2:  flip redpanda-console-active selector wholesale     │
   │           ──►  operator-managed Console v3  [active]          │
   │           ──►  standalone Console v3        [idle]            │
   │                                                                │
   │  step 3:  delete the standalone Deployment + Service + CM     │
   │           ──►  operator-managed Console v3  [active, sole]    │
   └──────────────────────────────────────────────────────────────┘
```

**Follow [`docs/console-bluegreen-upgrade.md`](docs/console-bluegreen-upgrade.md)
Step 5** for the full Phase 2b walkthrough — manifests, cutover order,
probe-protected verification.

The three manifests Phase 2b touches are all checked in:

| File | What it does |
| ---- | ------------ |
| [`manifests/console-cr.yaml`](manifests/console-cr.yaml) | the operator-managed Console (`spec.podLabels.console-version: managed-v3`) |
| [`manifests/console-active-service.yaml`](manifests/console-active-service.yaml) | the Service users / Ingress hit; selector flips wholesale from `console-version: v3` (Phase 0b) → `console-version: managed-v3` (Phase 2b) |
| [`manifests/console-v3-standalone.yaml`](manifests/console-v3-standalone.yaml) | the standalone v3 Deployment + ConfigMap + Service from Phase 0b — deleted in Phase 2b |

The operator's Console controller renders the CR into a Deployment +
ConfigMap + Service named `redpanda-console`. After it's Ready, apply
the updated `console-active-service.yaml` (the committed file already
has `console-version: managed-v3`), then `kubectl delete -f
manifests/console-v3-standalone.yaml`. Validated probe behavior in
[`docs/console-bluegreen-upgrade.md`](docs/console-bluegreen-upgrade.md)
applies identically here — the Service-selector flip is ~2 s, no
dropped requests when both backends are Ready.

**Notes:**
- Land all Phase 2b manifests in the **same git commit**: Console CR +
  active-Service selector flip + removal of the standalone v3
  Deployment / ConfigMap / Service. ArgoCD prunes them as part of the
  sync; if you split the commits, ArgoCD and the operator briefly fight
  over Deployment ownership.
- The Console CR's `spec.cluster.clusterRef.name` is the simplest way to
  point Console at the cluster — the operator resolves brokers, schema
  registry, and admin API URLs from the Redpanda CR's own status. For
  per-listener overrides see the `staticConfiguration` mode in
  `ClusterSource`.
- The `Console` CR's `spec` embeds `ConsoleValues`, which is a
  `PartialValues` of the upstream console chart (see
  `operator/api/redpanda/v1alpha2/console_types.go`). Common fields
  (`replicaCount`, `image`, `service`, `ingress`, `config`, `resources`,
  etc.) are exposed; very-niche values may not be expressible yet —
  open an issue against the operator if you hit one.
- Phase 2b runs against brokers on `v25.2.x` (from Phase 1) and operator
  `25.3.4` (from Phase 2). The cluster has no broker rolling restart
  pending at this point, so the Console-only cutover happens against a
  steady cluster. Doing it here rather than after Phase 5 means
  subsequent broker rolling restarts in Phases 3 and 5 happen with
  Console already in its CR-managed steady state.

**Exit criteria:**
- `kubectl -n redpanda get console redpanda-console -o jsonpath='{.status.readyReplicas}/{.status.replicas}'`
  → `1/1` (or however many replicas you set).
- `kubectl -n redpanda get pods -l console-version=managed-v3` → 1 pod
  Running, image `console:v3.7.x`.
- `kubectl -n redpanda get svc redpanda-console-active -o jsonpath='{.spec.selector}'`
  → `{ console-version: managed-v3 }`.
- Standalone v3 resources pruned: no `redpanda-console-v3` Deployment,
  Service, or ConfigMap in the namespace.
- Continuous probe shows zero failures across the cutover.

### Phase 3 — Redpanda broker 25.2.x → 25.3.x

**ArgoCD change:** [`applications/phase-3-redpanda-25.3.yaml`](applications/phase-3-redpanda-25.3.yaml).

Mirror of Phase 1. Note the customer's "Iceberg schema + topic retention"
breaking change is documented but **does not apply** here because the
customer has no Iceberg topics.

### Phase 4 — Operator 25.3.x → 26.1.x

**ArgoCD change:** [`applications/phase-4-operator-26.1.yaml`](applications/phase-4-operator-26.1.yaml).

This is the operator's CRD-shape change for the multicluster work; CRDs
land via the chart's pre-install Job. Verify
`kubectl get crds | grep redpanda.com` shows all expected types
including `nodepools.cluster.redpanda.com` (new in 25.3) and any
multicluster CRDs your topology uses.

### Phase 5 — Redpanda broker 25.3.x → 26.1.x

**ArgoCD change:** [`applications/phase-5-redpanda-26.1.yaml`](applications/phase-5-redpanda-26.1.yaml).

**Final rolling restart.** AKS K8s version must be `>=1.32` before
applying this phase (verified in Phase −1 pre-flight).

---

## Validation strategy

### OMB on a separate VM

A dedicated VM in the AKS VNet runs `openmessaging-benchmark` against the
Redpanda cluster's external Kafka listener (LoadBalancer Service). The
workload is sized at 10 MB/s — enough to surface partition leadership
churn during rolling restarts but small enough to fit on a 4‑vCPU VM
without the worker becoming the bottleneck.

Setup script: [`probes/omb-vm-setup.sh`](probes/omb-vm-setup.sh).
Driver config: [`probes/omb-driver-redpanda.yaml`](probes/omb-driver-redpanda.yaml).
Workload spec: [`probes/omb-workload-10mbps.yaml`](probes/omb-workload-10mbps.yaml).

The probe runs **continuously** from before Phase 0a starts until after
Phase 5 exits. The success criterion: zero `produce.failed` /
`consume.failed` for the entire window, p99 produce latency within the
SLO defined by the customer's existing dashboards.

### What "no downtime" means here

Concrete operational definition for the upgrade window:

- **Producers**: zero produce failures with `acks=all`,
  `enable.idempotence=true`. Brief leader re-election on a partition is
  invisible to the producer because of the franz-go retry loop and the
  60s default `delivery.timeout.ms`.
- **Consumers**: no rebalance loops > 30 s. Brief leader changes cause one
  consumer fetch retry; OMB's per-second metric should show no zero-bucket
  longer than 5 s.
- **Cluster admin**: `rpk cluster health` returns `Healthy: true` between
  every broker recycle and at the end of every phase.

Anything failing those bars stops the upgrade and triggers rollback (next
section).

### Optional second probe

For belt-and-suspenders, run a `rpk topic produce/consume` loop in a
sidecar pod inside the cluster, on a topic with `replication.factor=3`,
`min.insync.replicas=2`. If both probes go quiet at the same time, it's
the cluster; if only the OMB VM goes quiet, it's the network path.

---

## Rollback

Each phase is reversible by reverting the git commit that introduced it,
then `argocd app sync` against the prior `targetRevision`. **Operator
chart downgrades are safe**; **Redpanda chart downgrades require explicit
admin steps** because the broker version doesn't downgrade — see
[`docs/rollback.md`](docs/rollback.md) for the per-phase reversal
procedures and the few cases where a forward-fix is the only path
(e.g. once a broker has run a new minor, you can't roll its on-disk
metadata format back).

---

## File index

| File | Purpose |
| --- | --- |
| [`applications/phase-0a-operator-25.1.yaml`](applications/phase-0a-operator-25.1.yaml) | ArgoCD app — operator chart bump v2.4 → 25.1 |
| [`applications/phase-0b-redpanda-cluster.yaml`](applications/phase-0b-redpanda-cluster.yaml) | ArgoCD app — Redpanda chart 5.10 → 25.1 (Console v2→v3) |
| [`applications/phase-1-redpanda-25.2.yaml`](applications/phase-1-redpanda-25.2.yaml) | Redpanda 25.1.9 → 25.2 |
| [`applications/phase-2-operator-25.3.yaml`](applications/phase-2-operator-25.3.yaml) | Operator 25.1 → 25.3 |
| [`applications/phase-3-redpanda-25.3.yaml`](applications/phase-3-redpanda-25.3.yaml) | Redpanda 25.2 → 25.3 |
| [`applications/phase-4-operator-26.1.yaml`](applications/phase-4-operator-26.1.yaml) | Operator 25.3 → 26.1 |
| [`applications/phase-5-redpanda-26.1.yaml`](applications/phase-5-redpanda-26.1.yaml) | Redpanda 25.3 → 26.1 |
| [`values/`](values/) | Helm values overlay per chart version |
| [`manifests/redpanda-cluster.yaml`](manifests/redpanda-cluster.yaml) | The `Redpanda` CR template (kept stable across all phases) |
| [`probes/omb-vm-setup.sh`](probes/omb-vm-setup.sh) | One-shot installer for an Ubuntu 22.04 VM in the AKS VNet |
| [`probes/omb-driver-redpanda.yaml`](probes/omb-driver-redpanda.yaml) | OMB Redpanda driver config (brokers, SASL, TLS) |
| [`probes/omb-workload-10mbps.yaml`](probes/omb-workload-10mbps.yaml) | 10 MB/s, 16 partitions, 1 KB messages |
| [`docs/argocd-considerations.md`](docs/argocd-considerations.md) | Per-Application `ignoreDifferences` + sync-options |
| [`docs/console-v2-to-v3.md`](docs/console-v2-to-v3.md) | Schema migration table for Phase 0b |
| [`docs/rollback.md`](docs/rollback.md) | Per-phase reversal procedure |
