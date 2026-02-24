#!/usr/bin/env bash
set -e

echo "========================================================"
echo " Proxmox Host Script: Building Loki + Garage S3 LXC"
echo "========================================================"

# --- Configuration ---
# You can change these variables to fit your homelab
CTID=$(pvesh get /cluster/nextid)
HOSTNAME="loki-logs"
CORES=2
MEMORY=2048
DISK_SIZE="20G"
STORAGE="local-lvm"       # Change this if your VM storage is named differently (e.g., 'local-zfs')
TEMPLATE_STORAGE="local"  # Where Proxmox stores downloaded templates
PASSWORD="default"

# Detect Gateway for static IP configuration to ensure internet access
HOST_GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n 1)
if [ -z "$HOST_GATEWAY" ]; then
    # Fallback if detection fails, though this might need adjustment for specific networks
    HOST_GATEWAY="192.168.1.1"
fi
NETWORK="name=eth0,bridge=vmbr0,ip=192.168.1.223/24,gw=$HOST_GATEWAY"

echo "--> Selected Container ID: $CTID"
echo "--> Root Password will be: $PASSWORD"

# --- 1. Download the latest Debian 12 Template ---
echo "--> Finding and downloading the latest Debian 12 template..."
pveam update >/dev/null

# Cleanly find the template name. We strip ANSI color codes just in case.
TEMPLATE_NAME=$(pveam available --section system | sed 's/\x1b\[[0-9;]*m//g' | grep -i 'debian-12' | awk '{print $2}' | sort -r | head -n 1)

if [ -z "$TEMPLATE_NAME" ]; then
    echo "Error: Could not find a Debian 12 template."
    exit 1
fi

echo "--> Detected template: $TEMPLATE_NAME"
pveam download $TEMPLATE_STORAGE $TEMPLATE_NAME >/dev/null || true

# --- 2. Create and Start the LXC ---
echo "--> Creating LXC container $CTID..."

# Resolve the full Volume ID from storage to ensure we have a valid path for pct create
# This handles cases where the constructed path might be incorrect or if pveam output format varies.
TEMPLATE_VOLID=$(pvesm list $TEMPLATE_STORAGE --content vztmpl | grep "$TEMPLATE_NAME" | awk '{print $1}' | head -n 1)

if [ -z "$TEMPLATE_VOLID" ]; then
    echo "Warning: Could not find template volume ID using pvesm. Falling back to constructed path."
    TEMPLATE_VOLID="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
fi

echo "--> Using Template Volume ID: $TEMPLATE_VOLID"

pct create $CTID $TEMPLATE_VOLID \
  --arch amd64 \
  --hostname $HOSTNAME \
  --cores $CORES \
  --memory $MEMORY \
  --net0 $NETWORK \
  --storage $STORAGE \
  --rootfs ${STORAGE}:${DISK_SIZE} \
  --password $PASSWORD \
  --features nesting=1 \
  --unprivileged 1

echo "--> Starting container $CTID..."
pct start $CTID

echo "--> Waiting for container network to initialize..."
sleep 10

# --- 3. Create the Installation Payload ---
# We write the installation script locally on the PVE host first
PAYLOAD_FILE="/tmp/loki-garage-install-${CTID}.sh"

cat << 'EOF' > $PAYLOAD_FILE
#!/usr/bin/env bash
set -e

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y curl wget unzip jq sqlite3

# Install Garage
GARAGE_VERSION="v0.9.1"
wget -qO /usr/local/bin/garage "https://garagehq.deuxfleurs.fr/_releases/${GARAGE_VERSION}/x86_64-unknown-linux-musl/garage"
chmod +x /usr/local/bin/garage

mkdir -p /var/lib/garage/{meta,data}
mkdir -p /etc/garage
RPC_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)

cat <<CONFIG > /etc/garage/garage.toml
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "[::]:3901"
rpc_secret = "${RPC_SECRET}"

[s3_api]
s3_region = "homelab"
api_bind_addr = "[::]:3900"
root_domain = ".s3.garage.localhost"

[admin]
api_bind_addr = "[::]:3903"
CONFIG

cat <<SERVICE > /etc/systemd/system/garage.service
[Unit]
Description=Garage S3 Server
After=network.target
[Service]
ExecStart=/usr/local/bin/garage server
Restart=always
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now garage
sleep 3

NODE_ID=$(garage status | grep "NO" | awk '{print $1}')
garage layout assign -z dc1 -c 10G "$NODE_ID"
garage layout apply --version 1

KEY_OUTPUT=$(garage key create loki-key)
ACCESS_KEY=$(echo "$KEY_OUTPUT" | grep "Access key:" | awk '{print $3}')
SECRET_KEY=$(echo "$KEY_OUTPUT" | grep "Secret key:" | awk '{print $3}')

garage bucket create loki-logs
garage bucket allow loki-logs --read --write --owner loki-key

# Install Loki
LOKI_VERSION="3.0.0"
wget -qO loki.zip "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip"
unzip loki.zip
mv loki-linux-amd64 /usr/local/bin/loki
chmod +x /usr/local/bin/loki
rm loki.zip

mkdir -p /var/lib/loki
mkdir -p /etc/loki

cat <<CONFIG > /etc/loki/config.yaml
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
      insecure: true
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
CONFIG

cat <<SERVICE > /etc/systemd/system/loki.service
[Unit]
Description=Loki Log Aggregation System
After=network.target garage.service
[Service]
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/config.yaml
Restart=always
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now loki

echo "LOKI_ACCESS_KEY=${ACCESS_KEY}" > /root/loki_credentials.txt
echo "LOKI_SECRET_KEY=${SECRET_KEY}" >> /root/loki_credentials.txt
EOF

# --- 4. Push and Execute Payload in LXC ---
echo "--> Pushing installation script to LXC..."
pct push $CTID $PAYLOAD_FILE /root/install.sh -perms 755

echo "--> Executing installation inside LXC (this may take a minute)..."
pct exec $CTID -- /root/install.sh

# --- 5. Clean up and Report ---
rm $PAYLOAD_FILE
LXC_IP=$(pct exec $CTID -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
ACCESS_KEY=$(pct exec $CTID -- grep LOKI_ACCESS_KEY /root/loki_credentials.txt | cut -d= -f2)
SECRET_KEY=$(pct exec $CTID -- grep LOKI_SECRET_KEY /root/loki_credentials.txt | cut -d= -f2)

echo "========================================================"
echo " Deployment Complete!"
echo " Container ID:  $CTID"
echo " Hostname:      $HOSTNAME"
echo " IP Address:    $LXC_IP"
echo " Root Password: $PASSWORD"
echo " ------------------------------------------------------"
echo " Loki API:      http://${LXC_IP}:3100"
echo " Garage S3 API: http://${LXC_IP}:3900"
echo " S3 Access Key: $ACCESS_KEY"
echo " S3 Secret Key: $SECRET_KEY"
echo "========================================================"
