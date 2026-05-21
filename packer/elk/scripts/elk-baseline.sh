#!/bin/sh
# Bake-time baseline for the ELK image (Debian 12 + Elastic 8.x).
# Installs the Elastic GPG repo + Elasticsearch + Kibana + Logstash +
# the beat agent packages, but does NOT enable services. Deploy-time
# userdata sets the cluster config + passwords + enables services.
set -eu

echo "[elk-bake] apt-get update + upgrade ..."
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "[elk-bake] base packages ..."
apt-get -y install --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    gnupg \
    apt-transport-https \
    python3 \
    python3-yaml \
    rsync

echo "[elk-bake] adding Elastic 8.x apt repo ..."
# Idempotent — re-runs of the bake don't fail on already-present key.
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
  > /etc/apt/sources.list.d/elastic-8.x.list

apt-get -y update

echo "[elk-bake] installing Elasticsearch + Kibana + Logstash ..."
# --no-install-recommends keeps the image lean; defer the Logstash
# plugins to deploy-time (cluster-id-aware install).
apt-get -y install --no-install-recommends \
    elasticsearch \
    kibana \
    logstash

# DO NOT enable any service yet. Deploy-time userdata writes the real
# elasticsearch.yml / kibana.yml with the per-deploy network.host +
# cluster name + password, then enables and starts them.
echo "[elk-bake] disabling auto-start on bake (deploy-time enables) ..."
systemctl disable elasticsearch kibana logstash 2>/dev/null || true

# Stage beat installers in /opt/beat-pkgs/ so c2 / DC / member-server
# deploys can pull them from the ELK host over the spoke VNet —
# avoids relying on artifacts.elastic.co internet reachability from
# locked-down ranges. Deploy-time scp + dpkg -i is faster than the
# ~50 MB Elastic download per beat-agent host.
echo "[elk-bake] staging beat agent packages in /opt/beat-pkgs/ ..."
mkdir -p /opt/beat-pkgs
cd /opt/beat-pkgs
# Pin to the same major version we just installed for the server side.
ELASTIC_VERSION=$(dpkg -l elasticsearch 2>/dev/null | awk '/^ii/{print $3}' | head -1)
if [ -n "$ELASTIC_VERSION" ]; then
    echo "  beats version: $ELASTIC_VERSION"
    for beat in filebeat winlogbeat metricbeat; do
        # Linux .deb (Filebeat / Metricbeat agents on C2 boxes)
        curl -fsSL -o "${beat}-${ELASTIC_VERSION}-amd64.deb" \
            "https://artifacts.elastic.co/downloads/beats/${beat}/${beat}-${ELASTIC_VERSION}-amd64.deb" \
            || echo "  (failed to stage ${beat} .deb — deploy-time will fall back to direct fetch)"
        # Windows .msi (Winlogbeat on DC + members; Filebeat too if needed)
        if [ "$beat" = "winlogbeat" ] || [ "$beat" = "filebeat" ]; then
            curl -fsSL -o "${beat}-${ELASTIC_VERSION}-windows-x86_64.msi" \
                "https://artifacts.elastic.co/downloads/beats/${beat}/${beat}-${ELASTIC_VERSION}-windows-x86_64.msi" \
                || echo "  (failed to stage ${beat} .msi — deploy-time fallback)"
        fi
    done
fi

echo "[elk-bake] cleaning apt cache (shrinks captured image) ..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[elk-bake] baseline complete."
echo "[elk-bake] Elastic version installed: ${ELASTIC_VERSION:-unknown}"
echo "[elk-bake] Beat packages staged in /opt/beat-pkgs/:"
ls -la /opt/beat-pkgs/ 2>/dev/null || true
