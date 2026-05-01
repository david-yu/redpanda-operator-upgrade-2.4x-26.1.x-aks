# Rollback playbook

Each phase is reversible **up to the point a broker has actually run a
new minor**. Once a broker comes up on `25.2.x` (Phase 1) and writes to
its on-disk metadata, you can't downgrade that broker to `25.1.x` and
keep its data. Anything before broker restart is freely revertable.

## Reversibility matrix

| Phase | What changed | Revertable by | Caveat |
| ----- | ------------ | ------------- | ------ |
| 0a | Operator binary `v2.4 → 25.1` | `git revert` Phase 0a commit + `argocd app sync redpanda-operator --replace` | The chart name reverts from `operator` to `redpanda-operator`. Same one-time `--replace` dance. CRDs do not auto-downgrade — the new schemas remain. |
| 0b | Redpanda chart `5.10 → 25.1` (Console v2→v3) | `git revert` + sync. **No broker version change happened**, so this is the last freely reversible phase. | Console v3 → v2 image swap is fine; values block needs to revert too. |
| 1 | Broker `25.1.9 → 25.2.x` | **One-way.** Cannot downgrade brokers. | If the new chart caused issues but brokers haven't restarted yet (chart sync still in progress), revert + sync immediately to abort the rolling restart. After the first broker is `Ready` on the new minor, only forward-fix is supported. |
| 2 | Operator `25.1 → 25.3` | `git revert` + sync. Operator-only, no broker effect. | The 25.3 CRD schemas remain on the API server even after operator downgrade. Only matters if 25.3 added a CRD with required fields the 25.1 operator doesn't fill — none do for this customer's CR set. |
| 3 | Broker `25.2 → 25.3` | One-way (same logic as Phase 1). | |
| 4 | Operator `25.3 → 26.1` | `git revert` + sync. | Same caveat re: CRD schemas. |
| 5 | Broker `25.3 → 26.1` | One-way. | This is the terminal phase; "rollback" past here is a restore-from-backup exercise. |

## Mid-phase abort (during a rolling restart)

If OMB shows latency spikes or the operator's `rpk cluster health` poll
keeps returning `Healthy=false`, abort the in-progress rolling restart:

```bash
# 1. Stop the chart bump from continuing.
git revert --no-edit HEAD              # revert the Phase N commit
git push

# 2. Force ArgoCD to sync the previous state immediately.
argocd app sync redpanda-cluster --force

# 3. Confirm: any brokers already restarted on the new minor stay there;
#    pending brokers stay on the old minor (the operator only walks the
#    next ordinal once the previous one returns to the ISR).
kubectl -n redpanda get pods -o wide
kubectl -n redpanda exec rp-0 -c redpanda -- rpk cluster info
```

The result is a **mixed-minor cluster** running until you choose to roll
forward again. Redpanda supports mixed-minor for the duration of an
upgrade window; don't run that way for days.

## Operator-only rollback (Phases 0a, 2, 4)

Because operator versions don't touch broker on-disk state, these are
true rollbacks:

```bash
git revert --no-edit <phase-commit>
git push
# Phase 0a only:
argocd app sync redpanda-operator --replace
# Phase 2 / 4:
argocd app sync redpanda-operator
```

Confirm the operator came back at the prior version:

```bash
kubectl -n redpanda-operator get deploy redpanda-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

## Restore-from-backup (terminal failure)

If something irrecoverable happens during Phase 1, 3, or 5, the
escalation path is restoring topic data from tiered storage or external
backups. **The customer is not running tiered storage**, so the only
backup posture is whatever they've configured externally (mirror cluster,
Connect-based archival to S3, etc.). This is the strongest argument for:

1. Running this whole upgrade in a non-prod environment first.
2. Quiescing producer load (or pausing the OMB probe) before each broker
   restart phase, even though Redpanda is designed to handle restarts
   under load.

## Smoke checks that gate "rollback or proceed"

Run all of these between phases. ANY red light = halt and assess.

```bash
# Operator + CRDs healthy
kubectl -n redpanda-operator get pods
kubectl get crds | grep redpanda.com | wc -l                   # expect: 8 (stable set)

# Cluster healthy
kubectl -n redpanda exec rp-0 -c redpanda -- rpk cluster health -w 0s
kubectl -n redpanda exec rp-0 -c redpanda -- rpk cluster info

# CR reconciled
kubectl -n redpanda get redpanda redpanda \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'  # expect: True
kubectl -n redpanda get redpanda redpanda \
  -o jsonpath='{.status.conditions[?(@.type=="ResourcesSynced")].status}'

# OMB probe still pumping
ssh azureuser@<omb-vm> "tail -n 5 /var/log/omb/probe-*.log"
```
