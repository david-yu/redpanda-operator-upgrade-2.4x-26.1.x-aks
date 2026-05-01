#!/usr/bin/env bash
# Cloud-init / one-shot bootstrap for an Ubuntu 22.04 VM in the AKS VNet.
# Installs JDK 17, Maven, OpenMessaging-Benchmark, and drops the driver +
# workload configs in place. Idempotent: safe to re-run.
#
# Usage:
#   az vm create ... --custom-data probes/omb-vm-setup.sh
#
# Or after the VM is up:
#   sudo bash omb-vm-setup.sh

set -euo pipefail

OMB_DIR=${OMB_DIR:-/home/azureuser/openmessaging-benchmark}
OMB_REF=${OMB_REF:-master}                # pinned to upstream master
LOG_DIR=/var/log/omb

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  openjdk-17-jdk-headless maven git tmux jq curl ca-certificates

mkdir -p "$LOG_DIR"
chown -R azureuser:azureuser "$LOG_DIR"

if [[ ! -d "$OMB_DIR" ]]; then
  sudo -u azureuser git clone https://github.com/openmessaging/openmessaging-benchmark "$OMB_DIR"
fi
cd "$OMB_DIR"
sudo -u azureuser git fetch --depth 1 origin "$OMB_REF"
sudo -u azureuser git checkout "$OMB_REF"
sudo -u azureuser mvn -B -q -DskipTests package

# Drop in the Redpanda driver + workload configs alongside upstream's.
mkdir -p driver-kafka/configs/redpanda workloads/redpanda
cat > driver-kafka/configs/redpanda/redpanda.yaml <<'EOF'
# Replace by ../omb-driver-redpanda.yaml during deploy
EOF
cat > workloads/redpanda/upgrade-10mbps.yaml <<'EOF'
# Replace by ../omb-workload-10mbps.yaml during deploy
EOF

# Materialize the real configs from the cloud-init context (copied via
# `az vm run-command invoke --scripts ...` or scp).
if [[ -f /tmp/omb-driver-redpanda.yaml ]]; then
  cp /tmp/omb-driver-redpanda.yaml driver-kafka/configs/redpanda/redpanda.yaml
fi
if [[ -f /tmp/omb-workload-10mbps.yaml ]]; then
  cp /tmp/omb-workload-10mbps.yaml workloads/redpanda/upgrade-10mbps.yaml
fi
if [[ -f /tmp/run-probe.sh ]]; then
  cp /tmp/run-probe.sh "$OMB_DIR/run-probe.sh"
  chmod +x "$OMB_DIR/run-probe.sh"
fi
if [[ -f /tmp/grade.sh ]]; then
  cp /tmp/grade.sh "$OMB_DIR/grade.sh"
  chmod +x "$OMB_DIR/grade.sh"
fi

chown -R azureuser:azureuser "$OMB_DIR"

echo "OMB ready at $OMB_DIR"
echo "Run ./run-probe.sh after dropping driver/workload configs in place."
