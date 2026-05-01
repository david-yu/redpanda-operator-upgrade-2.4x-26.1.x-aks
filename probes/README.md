# OMB upgrade probe

Drives ~10 MB/s of produce + consume traffic against the Redpanda cluster
for the entire upgrade window from outside the AKS cluster, on a separate
VM. Zero produce/consume failures across all phases is the no-downtime
acceptance criterion.

## Topology

```
       ┌─────────────────────┐               ┌──────────────────────────────┐
       │  OMB worker VM      │  Kafka 9092   │  AKS                         │
       │  Standard_D4s_v3    │  ────────────►│  Redpanda — 3 brokers        │
       │  Ubuntu 22.04       │               │  Service type=LoadBalancer   │
       │  Java 17, Maven     │               │  (or PrivateLink/internal)   │
       │  openmessaging-     │               │                              │
       │  benchmark/         │               │  Operator (subject of test)  │
       └─────────────────────┘               └──────────────────────────────┘
            │                                       ▲
            └───── runs continuously ────────────────┘
                   from before Phase 0a
                   until after Phase 5
```

Place the VM in the **same VNet** as the AKS cluster (peering or shared
VNet). Hitting the public LoadBalancer over the internet works but adds
network jitter that makes p99 latency assertions noisier.

## Files

| File | Purpose |
| ---- | ------- |
| [`omb-vm-setup.sh`](omb-vm-setup.sh) | One-shot bootstrap for an Ubuntu VM — installs JDK, Maven, openmessaging-benchmark, drops the driver/workload configs in place |
| [`omb-driver-redpanda.yaml`](omb-driver-redpanda.yaml) | OMB Kafka-driver YAML pointed at the AKS Redpanda LB endpoint |
| [`omb-workload-10mbps.yaml`](omb-workload-10mbps.yaml) | 10 MB/s, 16 partitions, 1 KB messages, 4 producers + 4 consumers, 4‑hour duration |
| [`run-probe.sh`](run-probe.sh) | Wrapper that starts OMB and pipes per-second metrics into a CSV for grading later |
| [`grade.sh`](grade.sh) | Reads the CSV after the upgrade and reports max gap, error count, p99 latency |

## Provisioning the VM

```bash
# Same RG/VNet/subnet as the AKS cluster
az vm create \
  -g <rg> -n omb-probe \
  --image Ubuntu2204 --size Standard_D4s_v3 \
  --vnet-name <aks-vnet> --subnet <subnet-with-route-to-aks> \
  --admin-username azureuser --generate-ssh-keys \
  --custom-data probes/omb-vm-setup.sh
```

After cloud-init finishes (~3 min):

```bash
ssh azureuser@<vm-ip>
cd ~/openmessaging-benchmark
./run-probe.sh \
  --driver  drivers/redpanda.yaml \
  --workload workloads/upgrade-10mbps.yaml \
  --output    /var/log/omb/probe.csv
```

Leave the SSH session attached (or run inside `tmux`/`screen`) until all
phases complete. `./grade.sh /var/log/omb/probe.csv` summarizes the run.

## Caveats

- **Topic auto-create**: OMB creates a topic per run. If your cluster
  pins `auto_create_topics_enabled=false`, pre-create
  `omb-upgrade-test-1` with `--partitions 16 --replication-factor 3`
  before starting the probe.
- **SASL credentials**: the driver references a SASL user on Redpanda
  with PRODUCE/CONSUME ACLs on the test topic. Create it via the User
  CR (declarative) or `rpk security user create` (imperative) before
  starting the probe.
- **TLS**: if the cluster's external listener uses a self-signed CA,
  copy the CA bundle to the VM and reference it in
  `omb-driver-redpanda.yaml` under `commonClientConfig.ssl.truststore`.
- **Resource floor**: at 10 MB/s with 1 KB messages, OMB's worker JVM
  needs ~1 vCPU + ~2 GB RAM. A `Standard_D4s_v3` (4 vCPU / 16 GB) has
  ~3× headroom and won't bottleneck.
