# Validation results

This file documents three end-to-end validation runs on AKS:

- **Run 3 (2026-05-01, primary)**: full upgrade with Console blue/green threaded through Phase 0b. **Zero downtime on both Kafka and Console probes** (158k Kafka produces / 0 errors, 4.7k Console HTTP probes / 0 fails). [Jump to Run 3](#run-3--full-upgrade-with-console-bluegreen).
- **Run 2 (2026-05-01)**: focused Console v2 → v3 in-place test, four sub-tests A/B/C/D — all confirmed the operator can't roll Console in place. [Jump to Run 2](#run-2--focused-console-v2--v3-test).
- **Run 1 (2026-05-01)**: initial full upgrade run, surfaced the three big findings (chartVersion rejected, Flux removed in 25.2, Console can't roll in place). Console was disabled mid-run after the third issue surfaced. [Jump to Run 1](#run-1--initial-upgrade-run).

The customer's runbook should reflect the patterns from Run 3 — that's the supported path.

---

## Run 3 — full upgrade with Console blue/green

End-to-end run on a fresh AKS (subscription `sandbox-product`, RG
`claude-bg-test-99a89d`, eastus, 3 × Standard_D4s_v3, K8s 1.33.10).
Operator v2.4.6 + Redpanda chart 5.10.5 + broker v25.1.9 + Console v2.8.0
as the source state. Resource group deleted at the end of the run.

**Zero downtime on both Kafka and Console probes across all phases.**

| Phase | Action | Wall time | Kafka probe | Console probe |
| - | - | -: | -: | -: |
| 0a | operator v2.4.6 → v25.1.3 | ~37 s | clean | clean |
| 0b | chart 5.10 → embedded 25.1 + **Console v2 → v3 blue/green cutover** + disable operator-managed v2 | ~8 m 41 s (cutover itself: 2 s) | clean | clean |
| 1 | broker v25.1.9 → v25.2.14 | ~2 m 22 s | clean | clean |
| 2 | operator v25.1.3 → v25.3.4 | ~53 s | clean | clean |
| 3 | broker v25.2.14 → v25.3.14 | ~2 m 19 s | clean | clean |
| 4 | operator v25.3.4 → v26.1.3 | ~55 s | clean | clean |
| 5 | broker v25.3.14 → v26.1.6 | ~2 m 20 s | clean | clean |

**Total upgrade window:** ~20 minutes wall clock.

**Final probe totals:**

```
kafka-probe:    158,000 produces / 0 errors
console-probe:  4,700 HTTP 200 / 0 failures
```

**Final cluster state:** operator `v26.1.3`, brokers `v26.1.6`, Console
`v3.7.0` (blue/green standalone, operator-managed Console GC'd in
Phase 0b).

### Phase 0b — Console blue/green cutover detail

Three actions in one phase:

```
T_CHART_BUMP:    18:18:16Z   patched CR — removed chartRef.chartVersion
T_CUTOVER:       18:18:17Z   kubectl apply on redpanda-console-active
                              (selector replaced wholesale: {console-version: v3})
T_FLIP_COMPLETE: 18:18:19Z   active Service endpoint = v3 pod IP  ← 2 s
T_DISABLE_V2:    18:18:19Z   patched CR — console.enabled=false
                  18:18:59Z   operator GC'd the v2 Console Deployment
                  18:18:59Z   broker rolling restart begins (chart 5.10 → 25.1)
                  18:20:43Z   all 3 brokers Running on the new chart
```

The Console probe (4 Hz HTTP) saw 200 OK throughout, including across
the 2-second selector flip. The Kafka probe saw 0 produce errors during
the broker rolling restart (replicas=3, RF=3, min.insync.replicas=2).

The full per-second probe stream is in
[`run3-probe-log.txt`](run3-probe-log.txt) for posterity.

### How this run differed from the customer's plan

In addition to the three findings carried over from Runs 1 & 2 (chartVersion
rejected by 25.1+, useFlux:false mandatory before 25.2, Console blue/green
required), the only divergence from the customer's plan was the **Console
v2 disable** in Phase 0b. Once the active Service points at v3,
disabling the chart's Console subchart is a clean cleanup step. ArgoCD
sees the v2 Deployment + Service get pruned and converges in seconds.

The customer's runbook should treat Phase 0b as "**three** changes in one
commit": chartRef.chartVersion drop, Console blue/green cutover (apply the
new active Service spec), and `console.enabled: false` flip. ArgoCD
naturally renders that commit's changes in any order; the operator's
reconciler catches up within ~30 s.

---

## Run 2 — focused Console v2 → v3 test

(Originally a follow-up to verify the "Console v2→v3 needs ArgoCD
wholesale replace" claim in Run 1's report. Result: that claim was
wrong; operator can't roll Console at all. The blue/green pattern that
Run 3 then validated end-to-end was discovered here.)

See [`docs/console-bluegreen-upgrade.md`](docs/console-bluegreen-upgrade.md)
for the working pattern.

| Sub-test | Action | Result |
| - | - | :-: |
| A | drop only `chartRef.chartVersion` (keep explicit `console.image.tag: v2.8.0`) | Console stays v2.8.0 (expected) |
| B | also drop the explicit `console.image` block | **Console stays v2.8.0** — ArgoCD wholesale replace claim was wrong |
| C | delete the Deployment to force a re-render | Operator recreates at v2.8.0 |
| D | bump a reconcile annotation | unchanged |
| **+** | **deploy v3 standalone, flip Service selector wholesale** | **v3 serving in 2 s, 0 dropped probes** |

---

## Run 1 — initial upgrade run

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

### 3. Console v2 → v3: operator can't roll it; use blue/green instead

I claimed in an earlier draft that "ArgoCD wholesale replace doesn't
have this issue." That was wrong — verified with a follow-up focused
test on a fresh AKS (2026-05-01).

**Sub-tests, all on a single CR with Console v2.8.0 explicitly pinned,
operator already upgraded to v25.1.3:**

| # | Action | Result |
| - | ------ | :----: |
| A | Drop only `chartRef.chartVersion` (keep explicit `console.image.tag`) | Console stays v2.8.0 (expected) |
| B | Also drop the explicit `console.image` block (the "wholesale replace" claim) | **Console stays v2.8.0** — claim was wrong |
| C | Delete the `redpanda-console` Deployment to force re-render | Operator recreates at v2.8.0 again |
| D | Bump a reconcile annotation on the Redpanda CR | No change |

The operator's reconcile path keeps re-applying the v2.8.0 image from a
cached Helm release values block. Helm-template static analysis confirms
the chart's *default* Console image at chart 25.1.x is v3.1.0 — but the
operator never gets there from a CR that had v2.x state.

**Working pattern (validated in same run, 2026-05-01):** treat Console
v2 → v3 as a parallel deployment + Service-selector cutover, not as
operator-managed. Step-by-step in
[`docs/console-bluegreen-upgrade.md`](docs/console-bluegreen-upgrade.md).
Validation timing:

```
T_CUTOVER:        17:35:31.3Z   (kubectl apply on the active Service)
T_APPLIED:        17:35:32.3Z
T_ENDPOINT_FLIP:  17:35:33.3Z   (~2 s end-to-end)
Probe (4 Hz against active Service):
  pre-cutover:   100 OK / 0 fail
  post-cutover:  450 OK / 0 fail (probe ran 5 more min, then v2 was disabled)
```

**Zero failed probes across the entire window** including the cutover
itself. Once the cutover is confirmed, disable the chart's Console
subchart (`console.enabled: false`) and the operator garbage-collects v2.

**One trap worth a callout in the runbook:** `kubectl patch --type=merge`
on the active Service's `spec.selector` keeps prior keys; the v3 pod
(which doesn't have those keys) ends up orphaned. Use `kubectl apply`
(wholesale replace) or ArgoCD's normal sync, not merge.

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
