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
- Operator chart: `2.4.x` 📌 NOTE — the v2.4.x **operator binary** ships
  with the `redpanda-operator` chart at version `0.4.x` (e.g. `0.4.41`), not
  `2.4.x`. The customer is likely conflating binary tag and chart tag. This
  doesn't change the upgrade path; just confirm which exact chart name +
  version the source ArgoCD Application points at and document it before
  starting (`helm -n redpanda-system list`).
- Redpanda chart: `5.10.x` ✅
- Tiered storage: none ✅

### Target

- Redpanda: `26.1.x` ✅
- Operator binary + chart: `26.1.x` ✅
- Redpanda chart: `26.1.x` ✅

### Upgrade phases

| Phase | What changes | Broker restart? | OMB downtime expected |
| ----- | ------------ | :-------------: | :-------------------: |
| 0a    | Operator binary + chart `v2.4.x → 25.1.x`, CRDs reapplied | no | none |
| 0b    | Redpanda chart `5.10.x → 25.1.x` (Console v2→v3 side-effect) | StatefulSet rolling pod restart only if pod-spec drift | within `pdb.maxUnavailable` window |
| 1     | Redpanda broker `25.1.9 → 25.2.x`, chart `25.1.x → 25.2.x` | yes (rolling) | within `pdb.maxUnavailable` window |
| 2     | Operator binary + chart `25.1.x → 25.3.x` | no | none |
| 3     | Redpanda broker `25.2.x → 25.3.x`, chart `25.2.x → 25.3.x` | yes (rolling) | within `pdb.maxUnavailable` window |
| 4     | Operator binary + chart `25.3.x → 26.1.x` | no | none |
| 5     | Redpanda broker `25.3.x → 26.1.x`, chart `25.3.x → 26.1.x` | yes (rolling) | within `pdb.maxUnavailable` window |

### Customer's open questions

| Q | A |
| - | - |
| Phase 0b: Helm Chart `5.10.x → 25.1.x` (reconciled by Operator)? | **Yes.** With `spec.chartRef.useFlux: false`, the operator drives the chart upgrade in-process via `lifecycle.SyncAll`. With `useFlux: true`, the in-cluster Flux HelmRelease reconciles. Phase 0a should leave `useFlux` whatever it is today; phase 0b is where you'd flip to fluxless if desired (recommended — Flux dependency removed in operator 25.x+ for v2 controllers). |
| Phase 0b: Console v2 → v3 side effect — review migration guide first? | **Yes, mandatory.** See [`docs/console-v2-to-v3.md`](docs/console-v2-to-v3.md). Console v3 changes the values schema (`console.console.config` → `console.config`, several connector fields renamed) and bumps the Deployment image. The Redpanda chart 25.1.x's `console` subchart pin is `>=3.7.0-0`, so a chart bump pulls Console v3 unconditionally. Don't trip on this. |
| Phase 1: HTTP Proxy auth breaking change? | **Skip the workaround — customer is not running HTTP Proxy.** Confirmed `pandaproxy.enabled: false` in the customer's values. The breaking change is irrelevant. |
| Phase 3: Iceberg schema + topic retention? | **Skip — customer has no Iceberg topics.** No action. |
| Phase 5: K8s ≥ 1.32? | **AKS upgrade required first** if the cluster is on `<1.32`. AKS supports 1.32 GA across all regions. Document the AKS upgrade as Phase −1 (pre-flight) below. |
| Phase 5: FIPS SCRAM ≥ 14 chars? | **Skip — FIPS not enabled.** No action. |

### Deltas I'd recommend on top of the customer's plan

1. **Add a Phase −1 pre-flight** that captures (a) cluster spec + Redpanda CR + Console deployment as a known-good snapshot for rollback, (b) confirms AKS `>=1.32` (required for Phase 5), (c) records broker IDs / disk sizes / partition counts as a "before" baseline.
2. **Skip operator `25.2.x` is fine** — both `25.1.x` and `25.3.x` operators support clusters running `25.2.x`. The customer's "25.1 → 25.3" jump is supported.
3. **For Phase 0a, set `spec.chartRef.useFlux: false`** in the same change. Flux is being phased out and the new operator paths assume controller-managed reconcile. If the source cluster is currently Flux-managed, the operator will GC the HelmRelease/HelmRepository CRs in this phase; expect transient noise in ArgoCD and add an `IgnoreDifferences` for those types in the Application manifest until the GC settles.
4. **OMB rate of 10 MB/s** is comfortably within the smallest reasonable AKS-hosted Redpanda cluster (3 × Standard_D4s_v3 + premium SSD). Running OMB on a 4 vCPU VM with default driver settings produces ≈100 k msg/s at 1 KB; the workload here caps at 10 k msg/s for headroom.
5. **PDB tightness during Phase 1/3/5**: confirm `clusterSpec.statefulset.podDisruptionBudget.maxUnavailable: 1` and that replicas ≥ 3 with replication-factor ≥ 3 on production topics; otherwise rolling restarts can take a partition offline briefly.

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

### Phase 0b — Redpanda chart 5.10.x → 25.1.x (Console v2 → v3)

**ArgoCD change:** [`applications/phase-0b-redpanda-cluster.yaml`](applications/phase-0b-redpanda-cluster.yaml)

```yaml
spec:
  chartRef:
    chartName: redpanda
    chartVersion: 25.1.4                 # was 5.10.x
    helmRepositoryName: redpanda-repository
    useFlux: false                       # MIGRATE off Flux during this phase
  clusterSpec:
    image:
      tag: v25.1.9                       # NO broker version bump in this phase
    console:
      enabled: true
      # Console v3 schema lives at console.config (was console.console.config in v2).
      # See docs/console-v2-to-v3.md for the full diff.
      config:
        kafka: { brokers: ['rp-0.rp.redpanda.svc.cluster.local:9093', ...] }
```

**Notes:**
- The `chartRef.chartVersion` jump from `5.10.x` to `25.1.x` is the chart
  **rename**, not a versioned upgrade — Redpanda chart `5.10.x` and
  `25.1.x` share lineage but the major-version reset switched the
  versioning scheme. Internally most templates are compatible.
- Console v2 → v3 happens automatically because the chart's `console`
  subchart pin is `>=3.7.0-0`. Most config fields move from
  `console.console.config.*` to `console.config.*`. The chart 25.1.4
  release notes call this out; see [`docs/console-v2-to-v3.md`](docs/console-v2-to-v3.md)
  for a transcribed migration table.
- ArgoCD will see drift on the Console Deployment (image tag v2.x → v3.x).
  Auto-sync handles it.

**Exit criteria:**
- All Redpanda broker pods stay `Ready` throughout (rolling pod-spec drift
  if any).
- Console pod transitions to image `v3.7.x`, comes Ready, `/admin/health`
  returns 200.
- Old `HelmRelease`/`HelmRepository` CRs (from Flux) are GC'd.
- OMB throughput unaffected (any partition unavailability < `pdb` window).

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
