#!/bin/bash
# Run on fresh OVH VPS as root
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

echo "==> Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confold"

echo "==> Installing essentials..."
apt-get install -y -qq curl wget git vim htop ca-certificates gnupg lsb-release \
    ufw fail2ban unattended-upgrades jq cron

echo "==> Creating deploy user..."
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$DEPLOY_USER"
    passwd -l "$DEPLOY_USER"
fi
if [ -f /root/.ssh/authorized_keys ] && [ ! -s /home/$DEPLOY_USER/.ssh/authorized_keys ]; then
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
    /bin/systemctl status linear-clone, /usr/bin/docker system prune *
SUDO
chmod 440 /etc/sudoers.d/deploy

echo "==> Hardening SSH..."
[ -f /etc/ssh/sshd_config.orig ] || cp /etc/ssh/sshd_config /etc/ssh/sshd_config.orig
cp /etc/ssh/sshd_config.orig /etc/ssh/sshd_config
cat >> /etc/ssh/sshd_config <<SSH

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers $DEPLOY_USER
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

echo "==> Installing Docker..."
if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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
echo "✅ Bootstrap complete!"
echo ""
echo "Next: reconnect as the deploy user:"
echo "  ssh $DEPLOY_USER@$(hostname -I | awk '{print $1}')"
echo ""
echo "Then run install.sh"
