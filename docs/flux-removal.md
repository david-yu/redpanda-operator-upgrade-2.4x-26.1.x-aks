# Flux removal — mandatory `useFlux: false` flip before operator 25.2.x

## TL;DR

Operator **25.2.x removes Flux entirely**. The 25.2.x reconciler refuses to
manage any `Redpanda` CR whose `spec.chartRef.useFlux` is `true` —
the controller hits an early-return guard and the CR falls silently out
of management with no error event raised. Verified in the operator source
at [`operator/v25.2.4`](https://github.com/redpanda-data/redpanda-operator/blob/operator/v25.2.4/operator/internal/controller/redpanda/redpanda_controller.go#L937-L938):

```go
// Upgrade checks. Don't reconcile if UseFlux is true or if ChartRef is set.
if rp.Spec.ChartRef.UseFlux != nil && *rp.Spec.ChartRef.UseFlux {
    // ... skip ...
}
```

For an upgrade to land smoothly, **flip every `useFlux` to `false` while
still on operator 25.1.x or older** (where the dual mode is still
supported), and verify the cluster reconciled successfully in fluxless
mode **before** bumping the operator to 25.2.x or later.

## Where in the customer's phase plan this fits

The plan in the [README](../README.md) lands the flip in **Phase 0b**
(when the chart bumps from 5.10.x → 25.1.x). Phase 0a installs the
operator chart that supports both modes; Phase 0b is the chart bump that
also flips Flux. By Phase 2 (operator 25.1.x → 25.3.x — note that 25.3
also has Flux removed), `useFlux: false` is in place and the cluster
keeps reconciling normally.

If the customer prefers to do the flip earlier — for example, in Phase
0a's commit so it lands together with the operator binary bump — that's
fine: operator v2.4.x already supports `useFlux: false`. Just don't push
it past Phase 0b. **The hard deadline is "before Phase 2."**

## Step-by-step

```bash
# 1. Inventory all Redpanda CRs with useFlux unset or true.
kubectl get redpanda -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: useFlux={.spec.chartRef.useFlux}{"\n"}{end}'

# 2. Flip each CR. ArgoCD-managed: edit the manifest in git and let sync
#    take it. kubectl-imperative is fine for one-off testing:
kubectl -n redpanda patch redpanda <name> --type=merge \
  -p '{"spec":{"chartRef":{"useFlux":false}}}'

# 3. Wait for the operator to settle. With useFlux: false the operator
#    drives the chart upgrade in-process; the CR's status.conditions[Ready]
#    should re-converge to True within ~3-5 minutes.
kubectl -n redpanda wait --for=condition=Ready --timeout=10m \
  redpanda/<name>

# 4. Optional: clean up the now-orphan Flux CRs the operator was using.
#    These are safe to delete — they have no controllers attached after
#    the flip, and operator 25.2.x deletes them on the next reconcile
#    anyway, but doing it now keeps ArgoCD happy.
kubectl -n redpanda delete helmrelease,helmrepository \
  -l 'app.kubernetes.io/instance=redpanda' --ignore-not-found

# 5. Verify the cluster is healthy in fluxless mode BEFORE the Phase 2
#    operator bump.
kubectl -n redpanda exec redpanda-0 -c redpanda -- rpk cluster health -w 0s
kubectl -n redpanda get redpanda redpanda \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Both must be Healthy/True before proceeding.
```

## Verification gate — run before Phase 2

This is the single most important pre-flight check the customer's plan
was missing. Encode it into the runbook between Phase 1 and Phase 2:

```bash
# Hard fail if any Redpanda CR still has useFlux: true.
COUNT=$(kubectl get redpanda -A \
  -o jsonpath='{range .items[?(@.spec.chartRef.useFlux==true)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' | wc -l)
if [[ "$COUNT" -gt 0 ]]; then
  echo "BLOCK Phase 2: $COUNT Redpanda CR(s) still have useFlux: true:"
  kubectl get redpanda -A \
    -o jsonpath='{range .items[?(@.spec.chartRef.useFlux==true)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
  exit 1
fi
```

## Symptoms if the flip is missed

If the customer accidentally bumps to operator 25.2.x with `useFlux:
true` left on any CR:

- `kubectl get redpanda <name>` shows `Ready=False` or stale status,
  with no recent `lastTransitionTime`.
- The operator log shows zero `RedpandaReconciler.Reconcile` entries for
  the affected CR — the reconciler's early-return guard fires before
  any work or status update is attempted.
- The HelmRelease / HelmRepository CRs that the v2.4.x → 25.1.x
  operator was driving are still present but unowned (no controller
  watching them).
- Brokers keep running on whatever spec was last applied. **No data
  loss**, but any subsequent CR change (image tag bump, replica change)
  is silently ignored.

Recovery: flip `useFlux: false` and force a reconcile (e.g., `kubectl
-n redpanda annotate redpanda <name> reconcile.fluxcd.io/requestedAt=$(date +%s) --overwrite`).
The 25.2.x operator will then resume management.

## Why this isn't documented as a chart-version error

Unlike the chart-version pin (which the v2.4.x defluxed reconciler
guards with a clear `chartVersion needs to be "5.10.5"` error event),
the 25.2.x Flux skip happens silently because the operator treats the
guard as a "not for me" signal, not an error. Hence the need to verify
the flip explicitly before Phase 2 rather than rely on
operator-emitted alerts.
