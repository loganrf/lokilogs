#!/usr/bin/env bash
set -e

echo "========================================================"
echo " Starting Loki + Garage S3 Setup for Proxmox LXC"
echo "========================================================"

# 1. Install prerequisites
echo "--> Installing dependencies..."
apt-get update && apt-get install -y curl wget unzip jq jq sqlite3

# 2. Install Garage (S3 backend)
echo "--> Downloading and installing Garage..."
GARAGE_VERSION="v0.9.1" # Update to the latest stable version if needed
wget -qO /usr/local/bin/garage "https://garagehq.deuxfleurs.fr/_releases/${GARAGE_VERSION}/x86_64-unknown-linux-musl/garage"
chmod +x /usr/local/bin/garage

# Create Garage directories
mkdir -p /var/lib/garage/{meta,data}
mkdir -p /etc/garage

# Generate a random RPC secret for Garage
RPC_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)

# Write Garage config
cat <<EOF > /etc/garage/garage.toml
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1 # Single node homelab setup
rpc_bind_addr = "[::]:3901"
rpc_secret = "${RPC_SECRET}"

[s3_api]
s3_region = "homelab"
api_bind_addr = "[::]:3900"
root_domain = ".s3.garage.localhost"

[admin]
api_bind_addr = "[::]:3903"
EOF

# Setup Garage Systemd Service
cat <<EOF > /etc/systemd/system/garage.service
[Unit]
Description=Garage S3 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/garage server
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo "--> Starting Garage..."
systemctl daemon-reload
systemctl enable --now garage
sleep 3 # Wait for Garage to initialize

# 3. Initialize Single-Node Garage Topology & Bucket
echo "--> Configuring Garage topology and buckets..."
NODE_ID=$(garage status | grep "NO" | awk '{print $1}')
garage layout assign -z dc1 -c 10G "$NODE_ID"
garage layout apply --version 1

# Create keys and buckets
KEY_OUTPUT=$(garage key create loki-key)
ACCESS_KEY=$(echo "$KEY_OUTPUT" | grep "Access key:" | awk '{print $3}')
SECRET_KEY=$(echo "$KEY_OUTPUT" | grep "Secret key:" | awk '{print $3}')

garage bucket create loki-logs
garage bucket allow loki-logs --read --write --owner loki-key

# 4. Install Loki
echo "--> Downloading and installing Loki..."
LOKI_VERSION="3.0.0" # Update to latest stable if needed
wget -qO loki.zip "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip"
unzip loki.zip
mv loki-linux-amd64 /usr/local/bin/loki
chmod +x /usr/local/bin/loki
rm loki.zip

# Create Loki directories
mkdir -p /var/lib/loki
mkdir -p /etc/loki

# Write Loki config (using Garage S3 via tsdb)
cat <<EOF > /etc/loki/config.yaml
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  instance_addr: 127.0.0.1
  path_prefix: /var/lib/loki
  storage:
    s3:
      endpoint: 127.0.0.1:3900
      bucketnames: loki-logs
      access_key_id: ${ACCESS_KEY}
      secret_access_key: ${SECRET_KEY}
      insecure: true # Local traffic, no SSL needed
      s3forcepathstyle: true
  compactor_address: http://127.0.0.1:3100
  replication_factor: 1

schema_config:
  configs:
    - from: 2024-04-01
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /var/lib/loki/tsdb-index
    cache_location: /var/lib/loki/tsdb-cache
    shared_store: s3

compactor:
  working_directory: /var/lib/loki/compactor
  shared_store: s3
EOF

# Setup Loki Systemd Service
cat <<EOF > /etc/systemd/system/loki.service
[Unit]
Description=Loki Log Aggregation System
After=network.target garage.service

[Service]
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/config.yaml
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo "--> Starting Loki..."
systemctl daemon-reload
systemctl enable --now loki

echo "========================================================"
echo " Setup Complete!"
echo " Loki is listening on port 3100."
echo " Garage S3 is running on port 3900."
echo " Access Key: ${ACCESS_KEY}"
echo " Secret Key: ${SECRET_KEY}"
echo "========================================================"