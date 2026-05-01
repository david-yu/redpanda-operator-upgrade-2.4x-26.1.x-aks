# ArgoCD considerations for the upgrade window

Defaults that work fine for steady-state Redpanda management can fight
us during a chart-rename or CRD-shape upgrade. Apply the items below for
the duration of the upgrade and revert the temporary ones at the end.

## 1. `prune: false` on both Applications

For the upgrade window, set both `redpanda-operator` and
`redpanda-cluster` Applications to `automated.prune: false`. ArgoCD's
default behavior is to delete resources that aren't in the source; the
chart rename in Phase 0a (`redpanda-operator` → `operator`) means the old
release's Helm release Secret + tracking ConfigMap could be pruned in a
way that briefly orphans the operator Deployment. Pruning re-enables in
Phase 5's exit checklist.

## 2. `ServerSideApply=true` on every Application

Required for fields the operator owns (Redpanda CR's `status`, NodePool
status, etc.). Without it, ArgoCD reverts operator-driven mutations on
its next sync, which the operator immediately re-applies, producing a
diff loop visible in the UI as "OutOfSync" forever.

## 3. `ignoreDifferences` for operator-managed fields

```yaml
ignoreDifferences:
  - group: cluster.redpanda.com
    kind: Redpanda
    jsonPointers:
      - /status
      - /spec/clusterSpec/statefulset/replicas   # the operator owns
                                                 # rolling restart shape
                                                 # changes
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jsonPointers:
      - /metadata/annotations                    # controller-gen embeds
                                                 # version-specific tags
```

## 4. Chart-rename (Phase 0a) requires `--replace`

Because `spec.source.chart` changes from `redpanda-operator` (the
`v2.4.x` chart name) to `operator` (the `25.x+` chart name), ArgoCD
treats it as a brand-new Helm release. If you don't `--replace`, both
releases coexist briefly and that's how you end up with two Operator
Deployments contending for the same CRs.

```bash
git push                                           # phase 0a commit
argocd app sync redpanda-operator --replace        # ONE TIME — only Phase 0a
```

Subsequent phases (`25.1 → 25.3 → 26.1`) are the same chart name with a
new `targetRevision`, so a normal `argocd app sync redpanda-operator` is
all that's needed.

## 5. Sync waves

If the customer's ArgoCD setup has multiple Applications converging on
the same namespace (e.g. cert-manager, monitoring), use sync waves to
ensure CRDs land before the Application that uses them:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"   # CRDs first
```

For this customer's narrow setup (operator + cluster), the operator
chart's pre-install Job already gates on CRDs being applied before the
operator Deployment starts, so sync waves aren't strictly needed.

## 6. `RespectIgnoreDifferences=true` interacts with `selfHeal`

`selfHeal: true` would normally re-apply on any drift. Combined with
`ignoreDifferences`, drift inside the ignored paths is silently
tolerated — exactly what we want for operator-owned status fields.

## 7. Manage Application manifests via the same git repo

This repo (`david-yu/redpanda-operator-upgrade-2.4x-26.1.x-aks`) is the
source of truth for both the Application objects and the Redpanda CR.
Drop the `applications/` files into the customer's
`argocd-bootstrap` repo (or app-of-apps), and let normal ArgoCD reconcile
turn the phase tag into reality.
