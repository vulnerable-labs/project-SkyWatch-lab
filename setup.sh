#!/bin/bash
# Project SkyWatch Lab – GCP VM Startup Script
# Intentionally Vulnerable CTF Environment [Medium Difficulty]
# Attack Chain: SSRF → Cloud Metadata → S3 Bucket → SSH Access → Linux Capability PrivEsc
#
# Deployment:
#
#   1. Deploy the VM:
#
#      gcloud compute instances create skywatch-lab \
#        --zone=us-central1-a \
#        --machine-type=e2-medium \
#        --image-family=ubuntu-2204-lts \
#        --image-project=ubuntu-os-cloud \
#        --boot-disk-size=20GB \
#        --tags=skywatch-lab \
#        --metadata-from-file startup-script=setup.sh
#
#   2. Create firewall rules (HTTP for the portal):
#
#      gcloud compute firewall-rules create allow-skywatch \
#        --allow=tcp:80 \
#        --target-tags=skywatch-lab \
#        --description="SkyWatch lab: HTTP portal"
#
#   3. Browse to http://<EXTERNAL_IP>/ once setup completes (~5 min).
#

set -e

echo "[+] Starting Project SkyWatch Lab Setup..."

export DEBIAN_FRONTEND=noninteractive

# --- 1. System Dependencies ---
echo "[+] Installing dependencies..."
apt-get update
apt-get install -y python3 python3-pip python3-venv gcc iptables curl net-tools libcap2-bin git ca-certificates gnupg lsb-release jq iptables-persistent

# --- 2. Add Service Users ---
echo "[+] Creating monitor-admin user..."
useradd -m -s /bin/bash monitor-admin
echo "monitor-admin:ChangeMe123!" | chpasswd

echo "[+] Creating skywatch-web service user..."
useradd -m -s /bin/false skywatch-web

# Generate SSH keys for monitor-admin
su - monitor-admin -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
su - monitor-admin -c "ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ''"
su - monitor-admin -c "cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys"
su - monitor-admin -c "chmod 600 ~/.ssh/authorized_keys"

# --- 3. Repository Setup ---
REPO_URL="https://github.com/vulnerable-labs/project-SkyWatch-lab.git"
PROJECT_DIR="/opt/skywatch"

echo "[+] Cloning repository to $PROJECT_DIR..."
rm -rf "$PROJECT_DIR"
git clone "$REPO_URL" "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Ensure directories exist in case they are missing from the repo
mkdir -p "$PROJECT_DIR/web/templates"
mkdir -p "$PROJECT_DIR/web/static"
mkdir -p "$PROJECT_DIR/metadata_service"
mkdir -p "$PROJECT_DIR/s3_service"
mkdir -p "$PROJECT_DIR/agent"

# --- 4. Simulated S3 Bucket Setup ---
S3_DATA_DIR="/opt/s3_data/nebula-monitoring-backups"
mkdir -p "$S3_DATA_DIR"

# Copy the SSH private key to the S3 bucket directory
cp /home/monitor-admin/.ssh/id_rsa "$S3_DATA_DIR/monitor-admin_id_rsa"
chown root:root "$S3_DATA_DIR/monitor-admin_id_rsa"
chmod 644 "$S3_DATA_DIR/monitor-admin_id_rsa"

echo "Backup keys for SkyWatch monitoring agent.
Used for emergency SSH access to the monitoring node." > "$S3_DATA_DIR/readme.txt"

# --- 5. Python Environments & Requirements ---
echo "[+] Setting up Python environments..."
python3 -m venv "$PROJECT_DIR/venv"
"$PROJECT_DIR/venv/bin/pip" install flask requests psutil gunicorn

# --- 6. Create Systemd Services ---
echo "[+] Creating systemd services for web apps..."

# Web Dashboard (Port 80)
cat <<EOF > /etc/systemd/system/skywatch-web.service
[Unit]
Description=SkyWatch Web Dashboard
After=network.target

[Service]
User=skywatch-web
WorkingDirectory=$PROJECT_DIR/src/web
Environment="PATH=$PROJECT_DIR/venv/bin"
ExecStart=$PROJECT_DIR/venv/bin/gunicorn --workers 3 --bind 0.0.0.0:8000 app:app

[Install]
WantedBy=multi-user.target
EOF

chown -R skywatch-web:skywatch-web $PROJECT_DIR/src/web

# Metadata Service (Port 8080)
cat <<EOF > /etc/systemd/system/skywatch-metadata.service
[Unit]
Description=SkyWatch Cloud Metadata Service
After=network.target

[Service]
User=root
WorkingDirectory=$PROJECT_DIR/src/metadata_service
Environment="PATH=$PROJECT_DIR/venv/bin"
ExecStart=$PROJECT_DIR/venv/bin/gunicorn --workers 2 --bind 127.0.0.1:8080 metadata:app

[Install]
WantedBy=multi-user.target
EOF

# S3 Service (Port 8081)
cat <<EOF > /etc/systemd/system/skywatch-s3.service
[Unit]
Description=SkyWatch Simulated S3 Service
After=network.target

[Service]
User=root
WorkingDirectory=$PROJECT_DIR/src/s3_service
Environment="PATH=$PROJECT_DIR/venv/bin"
ExecStart=$PROJECT_DIR/venv/bin/gunicorn --workers 2 --bind 127.0.0.1:8081 s3:app

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now skywatch-web skywatch-metadata skywatch-s3

echo "[*] Waiting for services to become healthy..."
sleep 5

# --- 7. Configure iptables routing for metadata IP (169.254.169.254 to Localhost:8080) ---
echo "[+] Configuring iptables for cloud metadata..."
# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Route 169.254.169.254 to port 8080 locally ONLY for the web application user.
# This ensures that the real GCP VM can still access its own metadata!
iptables -t nat -A OUTPUT -d 169.254.169.254 -p tcp --dport 80 -m owner --uid-owner skywatch-web -j DNAT --to-destination 127.0.0.1:8080

# Forward external port 80 to the web application running on port 8000
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8000
# Also redirect localhost traffic aimed at port 80 (needed if SSRF tests itself)
iptables -t nat -A OUTPUT -d 127.0.0.1 -p tcp --dport 80 -j REDIRECT --to-port 8000

iptables-save > /etc/iptables/rules.v4

# --- 8. Compile and Setup the Vulnerable Capability Binary ---
echo "[+] Setting up capability binary..."
mkdir -p /var/log/skywatch
chown monitor-admin:monitor-admin /var/log/skywatch

gcc "$PROJECT_DIR/src/agent/skywatch-agent.c" -o /usr/bin/skywatch-agent
chmod 755 /usr/bin/skywatch-agent
# VULNERABILITY: Assigned cap_dac_override allows ignoring RWX permissions on files.
setcap cap_dac_override+ep /usr/bin/skywatch-agent

# Give the monitor-admin a sample config layout with instructions in comments so they understand
su - monitor-admin -c "cat << 'EOF' > ~/.skywatch.conf
# SkyWatch Agent Configuration
# Do not modify manually unless testing.

[logging]
path=/var/log/skywatch/agent.log
EOF"

# --- 9. Deploy CTF Flags ---
echo "[+] Deploying flags..."
# User Flag
echo "VulnOs{skywatch_user_access_b9f2a}" > /home/monitor-admin/user.txt
chown monitor-admin:monitor-admin /home/monitor-admin/user.txt
chmod 600 /home/monitor-admin/user.txt

# Root Flag
echo "VulnOs{capability_root_pwn_c1d4e}" > /root/root.txt
chmod 600 /root/root.txt

# --- 10. MOTD ---
EXTERNAL_IP=$(curl -sf -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip \
    2>/dev/null || hostname -I | awk '{print $1}')

cat > /etc/motd << MOTD

╔══════════════════════════════════════════════════════════════════╗
║        Project: SkyWatch          —  CTF Lab  [MEDIUM]           ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  Target  →  http://${EXTERNAL_IP}/                               ║
║  Flags   →  VulnOs{...}  (2 total)                               ║
║                                                                  ║
║  Attack Chain                                                    ║
║  ─────────────────────────────────────────────────────────────── ║
║  1. SSRF           Internal connect checker → Meta-data          ║
║  2. Cloud Metadata Retrieve temporary IAM credentials            ║
║  3. S3 Bucket Enum Use IAM creds to read backup bucket           ║
║  4. SSH Access     Extract id_rsa from bucket → monitor-admin    ║
║  5. Linux Cap      Abuse cap_dac_override → Arbitrary File Write ║
║                                                                  ║
║  Services (Local systemd)                                        ║
║  ─────────────────────────────────────────────────────────────── ║
║  web       :80     SkyWatch Status Dashboard (+ SSRF)            ║
║  metadata  :8080   AWS IAM Mock Endpoint (169.254.169.254)       ║
║  s3        :8081   AWS S3 Mock Endpoint (nebula-monitoring-backups)║
║  agent             /usr/bin/skywatch-agent                       ║
║                                                                  ║
║  GCP SSH: key-based only via OS Login (no passwords)             ║
╚══════════════════════════════════════════════════════════════════╝

MOTD

echo "[*] Project: SkyWatch lab setup complete."
echo "[*] Lab URL: http://${EXTERNAL_IP}/"
