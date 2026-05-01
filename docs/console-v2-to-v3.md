# Console v2 → v3 migration

The Redpanda chart's `console` subchart pin moves from `2.x` (chart 5.10.x
era) to `>=3.7.0-0` in chart 25.1.x. The chart bump in **Phase 0b**
pulls the new image and a different values schema.

The customer's existing `redpanda.values.yaml` block under `console:` needs
to be rewritten before that commit lands, otherwise the Console pod
crash-loops on startup with `unknown field` errors when parsing
`config.yaml`. The chart itself doesn't transform the schema.

## Schema diff (the parts that matter for this customer)

Console v2 nested `console.config` under another `console.console.config`
key when used as a subchart. v3 flattens this. Apply the table below
mechanically.

| v2 path (chart 5.10) | v3 path (chart 25.1+) | Notes |
| --- | --- | --- |
| `console.console.config.kafka.brokers` | `console.config.kafka.brokers` | unchanged shape |
| `console.console.config.kafka.tls` | `console.config.kafka.tls` | unchanged shape |
| `console.console.config.kafka.sasl` | `console.config.kafka.sasl` | unchanged shape |
| `console.console.config.kafka.schemaRegistry` | `console.config.schemaRegistry` | **moved up one level** |
| `console.console.config.connect` | `console.config.kafkaConnect` | **renamed** |
| `console.console.config.redpanda.adminApi` | `console.config.redpanda.adminApi` | unchanged shape |
| `console.console.config.login` | `console.config.authentication` | **renamed**; OIDC sub-block fields renamed too — see Console v3 release notes |
| `console.console.config.enterprise` | `console.config.licenses` | **renamed**; license is now an array |
| `console.console.config.cloud` | (removed) | cloud-only field, drop from on-prem values |
| `console.image.tag` (defaulted to `v2.x.x`) | (don't pin) | let the subchart's `appVersion: v3.7.x` win |

The full v3 schema reference: <https://docs.redpanda.com/current/reference/console/config/>.

## Functional differences worth knowing

1. **The Console v3 binary's first-run reads its old config from disk and
   migrates internal state**. Persistent volumes are NOT used by Console,
   so this is a no-op for our deployment — fresh pod, fresh config.
2. **Authentication providers**: v3 reorganized the auth section. If the
   customer is using OIDC/Google/GitHub login, the `login.<provider>`
   block becomes `authentication.oidc` or `authentication.providers[].*`.
3. **Default theme** changed; cosmetic only.

## What this looks like in our manifest

`manifests/redpanda-cluster.yaml` already uses the v3 schema (see the
`console.config:` block). The customer's existing values file is NOT in
this repo — they need to re-base their values onto the new schema in the
same commit that bumps the chart version.

## Smoke test after Phase 0b

```bash
kubectl -n redpanda get deploy redpanda-console -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expect: docker.redpanda.com/redpandadata/console:v3.7.x

kubectl -n redpanda port-forward svc/redpanda-console 8080:8080 &
curl -fsS http://localhost:8080/admin/health
# Expect: 200 with `"status":"ok"`

# UI smoke
open http://localhost:8080
# - login works
# - cluster overview lists the 3 brokers
# - topics page lists the OMB probe topic
```
