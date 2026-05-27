#!/bin/bash
# Run on a fresh Ubuntu 22.04 VPS as root.
# Idempotent: safe to re-run.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

echo "==> Removing any pre-installed web servers (nginx/apache)..."
# Many cloud images ship with these. They occupy ports 80/443 and
# would block Caddy from starting. Stop them BEFORE installing Docker.
for svc in nginx apache2; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc"
        systemctl disable "$svc"
    fi
done
apt-get remove -y --purge nginx nginx-common nginx-core apache2 2>/dev/null || true

echo "==> Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confold"

echo "==> Installing essentials..."
apt-get install -y -qq curl wget git vim htop ca-certificates gnupg lsb-release \
    ufw fail2ban unattended-upgrades jq cron pwgen

echo "==> Creating deploy user..."
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$DEPLOY_USER"
fi

# Generate a strong password for the deploy user automatically.
# Save it to a root-only file so the admin can find it later.
# This handles the case where the admin SSH'd into root with a
# password (no SSH key) — the deploy user needs SOME way to log in.
DEPLOY_PASSWORD_FILE="/root/deploy-user-password.txt"
if [ ! -f "$DEPLOY_PASSWORD_FILE" ]; then
    DEPLOY_PASS=$(pwgen -s 20 1)
    echo "$DEPLOY_PASS" > "$DEPLOY_PASSWORD_FILE"
    chmod 600 "$DEPLOY_PASSWORD_FILE"
    echo "$DEPLOY_USER:$DEPLOY_PASS" | chpasswd
    echo "==> Deploy user password saved to $DEPLOY_PASSWORD_FILE"
fi

# Copy SSH keys from root if they exist (won't hurt if password-only)
if [ -s /root/.ssh/authorized_keys ] && [ ! -s /home/$DEPLOY_USER/.ssh/authorized_keys ]; then
    mkdir -p /home/$DEPLOY_USER/.ssh
    cp /root/.ssh/authorized_keys /home/$DEPLOY_USER/.ssh/
    chown -R "$DEPLOY_USER:$DEPLOY_USER" /home/$DEPLOY_USER/.ssh
    chmod 700 /home/$DEPLOY_USER/.ssh
    chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys
fi

echo "==> Sudoers for deploy user..."
cat > /etc/sudoers.d/deploy <<SUDO
$DEPLOY_USER ALL=(root) NOPASSWD: /bin/systemctl restart linear-clone, \
    /bin/systemctl start linear-clone, /bin/systemctl stop linear-clone, \
    /bin/systemctl status linear-clone, /bin/systemctl enable linear-clone, \
    /bin/systemctl disable linear-clone, /usr/bin/docker system prune *, \
    /bin/cp /home/$DEPLOY_USER/linear-clone/systemd/*, \
    /bin/sed -i * /etc/systemd/system/linear-*, \
    /bin/systemctl daemon-reload
SUDO
chmod 440 /etc/sudoers.d/deploy

echo "==> Hardening SSH..."
[ -f /etc/ssh/sshd_config.orig ] || cp /etc/ssh/sshd_config /etc/ssh/sshd_config.orig
cp /etc/ssh/sshd_config.orig /etc/ssh/sshd_config
cat >> /etc/ssh/sshd_config <<SSH

PermitRootLogin no
PubkeyAuthentication yes
AllowUsers $DEPLOY_USER

# Allow password auth for deploy user only (key auth still preferred)
Match User $DEPLOY_USER
    PasswordAuthentication yes
SSH
sshd -t && systemctl restart ssh

echo "==> Configuring firewall..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

echo "==> Enabling fail2ban..."
systemctl enable --now fail2ban

echo "==> Removing Ubuntu's docker packages if present..."
# Ubuntu ships `docker.io` and `docker-compose` v1.29.2 in its own
# repos. v1.29.2 has the known KeyError: 'ContainerConfig' bug when
# recreating containers built by modern Docker engines. We must
# uninstall these before adding Docker's official repo, otherwise
# apt won't replace them with the upstream packages.
apt-get remove -y --purge docker docker.io docker-doc docker-compose \
    docker-compose-v2 podman-docker containerd runc 2>/dev/null || true

echo "==> Adding Docker's official apt repo..."
# Always (re)add — bootstrap is idempotent and we must not skip this
# step if Docker happens to already be installed, otherwise the
# compose plugin install below will fail with "Unable to locate
# package docker-compose-plugin".
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq

echo "==> Installing Docker Engine + Compose v2 plugin..."
# Compose v2 only. The legacy `docker-compose` (Python, v1.x) is
# intentionally NOT installed — it has the ContainerConfig bug.
apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Sanity check: refuse to continue if the plugin isn't actually usable.
if ! docker compose version >/dev/null 2>&1; then
    echo "❌ 'docker compose' did not install correctly. Aborting."
    exit 1
fi

usermod -aG docker "$DEPLOY_USER"
systemctl enable --now docker

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<DOCKER
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "50m", "max-file": "5"},
  "live-restore": true
}
DOCKER
systemctl restart docker

echo "==> Adding swap..."
if ! swapon --show | grep -q .; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

mkdir -p /home/$DEPLOY_USER/linear-clone
chown -R "$DEPLOY_USER:$DEPLOY_USER" /home/$DEPLOY_USER

echo ""
echo "============================================================"
echo "✅ Bootstrap complete!"
echo "============================================================"
echo ""
if [ -f "$DEPLOY_PASSWORD_FILE" ]; then
    echo "📌 IMPORTANT: Deploy user password is in $DEPLOY_PASSWORD_FILE"
    echo "    View it now: cat $DEPLOY_PASSWORD_FILE"
    echo ""
fi
echo "Next: reconnect as deploy user:"
echo "  ssh $DEPLOY_USER@$(hostname -I | awk '{print $1}')"
echo ""
echo "Then run: bash install.sh"
