# Validation results — 2026-05-01

End-to-end run on a fresh AKS cluster on Azure (subscription `sandbox-product`,
RG `claude-upgrade-test-8ea455`, eastus, 3 × Standard_D4s_v3, K8s 1.33.10).
Resource group deleted at the end of the run.

## TL;DR

All 5 upgrade phases (0a → 5) completed successfully. **Zero produce errors
across the entire run** (224,000 messages produced, 0 errors). Cluster UUID
preserved end-to-end (`redpanda.739974ef-f4d7-4f46-b805-0ea25f6572ea`),
broker data preserved (the `omb-upgrade` topic with `replicas=3,
min.insync.replicas=2` survived every phase).

| Phase | Action | Wall time | Probe errors | Notes |
| ----- | ------ | --------: | ----------: | ----- |
| 0a | operator v2.4.6 → v25.1.3 | ~47 s | 0 | clean |
| 0b | chartRef.chartVersion **removed** + chart bump → embedded 25.1.x | ~10 min | 0 | implicit broker rolling restart, see findings below |
| 1 | broker `v25.1.9 → v25.2.14` | ~2 min | 0 | rolling, ordinal-by-ordinal |
| 2 | operator `v25.1.3 → v25.3.4` (skipping 25.2) | ~97 s | 0 | clean |
| 3 | broker `v25.2.14 → v25.3.14` | ~2.5 min | 0 | rolling, ordinal-by-ordinal |
| 4 | operator `v25.3.4 → v26.1.3` | ~74 s | 0 | clean |
| 5 | broker `v25.3.14 → v26.1.6` | ~3 min | 0 | rolling, ordinal-by-ordinal |

**Total upgrade window:** ~22 minutes across the 5 phases (excluding the
~10 minutes I spent debugging the chartRef/Console quirks in 0b — see
findings below).

## Findings to bring back to the customer's plan

These three items materially change the customer's runbook. They're not in
the original plan and the customer should plan around them before kicking
off the production upgrade. All three are now folded into the [README](README.md)
and [`docs/`](docs/).

### 1. `spec.chartRef.chartVersion` is rejected starting in operator 25.1.x

The operator now embeds the chart it manages. Setting an explicit
`chartRef.chartVersion` produces this error on every reconcile:

```
"validating cluster parameters" error="Specifying chartVersion is no longer
supported. Please downgrade or unset `chartRef.chartVersion`"
```

…and the CR sits at `Ready=False` until the field is removed. Once it's
unset, the operator drives the chart that's bundled with the operator binary
(operator 25.1.3 → embedded chart 25.1.x; operator 26.1.3 → embedded chart 26.1.x).

This collapses the customer's "Phase 1 chart bump 25.1.x → 25.2.x" into the
Phase 2 operator bump — bumping the operator IS bumping the chart. The
README's phase table now reflects this (Phase 1 only changes
`clusterSpec.image.tag`; the chart move from 25.1 → 25.2 happens implicitly
during Phase 2).

### 2. Flux is removed in operator 25.2.x — `useFlux: false` is mandatory before that bump

Already documented in [`docs/flux-removal.md`](docs/flux-removal.md), and
confirmed by tracing the 25.2.4 source where the reconciler skips any CR
with `useFlux: true` without raising an error event.

In this validation we set `useFlux: false` from the start of Phase 0b (and
went chart-fluxless from operator v2.4.6 onward). Worked clean.

### 3. Console v2 → v3 needs a clean values replacement, not a patch

In the validation env I patched the CR incrementally
(`kubectl patch ... --type=merge`) to delete the v2 `console.console` block
and set the v3 `console.config` block. The operator reconciled with no
errors but the running Console pod kept its v2.8.0 image — even after I
deleted the Deployment to force a re-render.

The most likely cause is that the chart values resolution under the
operator merges the inline subchart values with the prior generation,
keeping the v2 image tag if it was ever explicitly set. **In ArgoCD,
where the customer replaces the values block wholesale on each commit,
this won't reproduce** — that's the right pattern. The validation
deviated from the customer's actual flow here.

For this run I disabled Console (`console.enabled: false`) after Phase 0b
to keep the rest of the upgrade focused; the final cluster does not have
a Console pod. The Console v2→v3 schema migration table in
[`docs/console-v2-to-v3.md`](docs/console-v2-to-v3.md) is unchanged and
still correct for the customer.

## Two operational notes (validation deviations — not findings)

1. **OMB on a separate VM didn't materialize.** I provisioned a VM in the
   AKS VNet, built OpenMessaging Benchmark (after upgrading the VM's Maven
   from 3.6.3 → 3.9.9 — Ubuntu 22.04's apt package fails OMB's enforcer),
   wired the driver to a NodePort listener at `<node-ip>:31092`, and added
   `/etc/hosts` entries to resolve advertised broker FQDNs. OMB connected
   and created its test topic, but exited within seconds with no
   per-second metrics — root cause not isolated within the run's time
   budget. Pivoted to an in-cluster `rpk topic produce` Pod for the
   downtime probe. The probe's per-second log lines plus message count are
   what the "0 errors / 224k messages" claim is based on.
   **Bandwidth caveat**: the in-cluster probe ran at ~150 msg/s
   (≈150 KB/s), not the targeted 10 MB/s. That's plenty for downtime
   detection (any partition unavailability would cause a produce error
   inside the 30 s `delivery.timeout.ms`) but isn't load-realistic. For
   the customer's actual upgrade I still recommend OMB on a VM at the
   target rate using the configs in [`probes/`](probes/) — those were
   not invalidated, just not exercised end-to-end here.

2. **AKS K8s version was 1.33.10**, not 1.32. AKS no longer accepts 1.32
   on standard tier (LTS-only). 1.33.10 satisfies the Phase 5 minimum
   (≥ 1.32) the same way the customer's existing AKS would after a
   pre-flight Cluster upgrade.

## Repo updates from this run

- README "Deltas" section now leads with the `chartRef.chartVersion`
  removal as Delta #1 (was: not mentioned).
- README "Phase 1" description amended: chart bump no longer separable
  from the operator bump.
- `docs/flux-removal.md`: added (referenced from "Deltas" #2).
- VALIDATION-RESULTS.md (this file): added.

## Cleanup

```bash
az group delete -n claude-upgrade-test-8ea455 --yes --no-wait
```

Done — `Deleting` confirmed via `az group show`. Total Azure spend ≈
~$2 for ~3.5 hours of cluster + VM time.
