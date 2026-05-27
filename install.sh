#!/bin/bash
# Run as the deploy user after bootstrap.sh
set -euo pipefail

[ "$(whoami)" != "root" ] || { echo "Run as deploy user, not root"; exit 1; }

APP_DIR="$HOME/linear-clone"
DEPLOY_REPO="${DEPLOY_REPO:-ankit-chowdhary/linear-deploy}"

# Auto-detect which docker compose command works on this server.
# Modern systems have `docker compose` (space). Older Ubuntu 22.04
# may only have `docker-compose` (hyphen). We pick whichever works.
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "❌ Neither 'docker compose' nor 'docker-compose' is installed."
    echo "    Re-run bootstrap.sh as root to fix."
    exit 1
fi
echo "==> Using compose command: $DC"

read -rp "GitHub username: " GHCR_USER
read -rp "Image namespace (your GitHub username): " IMAGE_NAMESPACE
read -rsp "GitHub PAT (read:packages scope): " GHCR_TOKEN; echo
read -rp "Domain (e.g. linear.example.com): " DOMAIN
read -rp "Let's Encrypt email: " LE_EMAIL

cd "$HOME"
if [ ! -d "$APP_DIR/.git" ]; then
    echo "==> Cloning deploy repo..."
    git clone "https://github.com/${DEPLOY_REPO}.git" "$APP_DIR"
fi

cd "$APP_DIR"
git pull

echo "==> Generating secrets..."
mkdir -p secrets

# CRITICAL FIX: use openssl rand -hex instead of -base64.
# hex output only contains 0-9 and a-f — guaranteed URL-safe.
# base64 can include / + = which break postgres:// connection URLs.
[ -f secrets/pg_password.txt ]    || openssl rand -hex 24 > secrets/pg_password.txt
[ -f secrets/jwt_secret.txt ]     || openssl rand -hex 48 > secrets/jwt_secret.txt
[ -f secrets/report_api_key.txt ] || openssl rand -hex 32 > secrets/report_api_key.txt
chmod 600 secrets/*.txt

echo "==> Writing .env.prod..."
cat > .env.prod <<ENV
DOMAIN=${DOMAIN}
LE_EMAIL=${LE_EMAIL}
IMAGE_NAMESPACE=${IMAGE_NAMESPACE}
PG_USER=linear
PG_DB=linear
PG_PASSWORD=$(cat secrets/pg_password.txt)
JWT_SECRET=$(cat secrets/jwt_secret.txt)
REPORT_API_KEY=$(cat secrets/report_api_key.txt)
ENVIRONMENT=production
BACKEND_IMAGE=ghcr.io/${IMAGE_NAMESPACE}/linear-clone-backend:latest
FRONTEND_IMAGE=ghcr.io/${IMAGE_NAMESPACE}/linear-clone-frontend:latest
ENV
chmod 600 .env.prod

echo "==> Logging in to GHCR..."
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

# Stop any pre-existing web servers (nginx, apache) that might
# still be running and block port 80.
echo "==> Ensuring ports 80/443 are free..."
for svc in nginx apache2; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        sudo systemctl stop "$svc" || true
        sudo systemctl disable "$svc" || true
    fi
done

echo "==> Pulling images..."
set -a; source .env.prod; set +a
$DC -f docker-compose.prod.yml pull

echo "==> Installing systemd units..."
sudo cp systemd/linear-clone.service /etc/systemd/system/
sudo cp systemd/linear-backup.service /etc/systemd/system/
sudo cp systemd/linear-backup.timer /etc/systemd/system/

# Inject the right compose command into the systemd files based on
# what was detected available on this system.
sudo sed -i "s|__DOCKER_COMPOSE__|$DC|g" /etc/systemd/system/linear-clone.service
sudo sed -i "s|__DOCKER_COMPOSE__|$DC|g" /etc/systemd/system/linear-backup.service
sudo sed -i "s|/home/deploy/linear-clone|$APP_DIR|g" /etc/systemd/system/linear-*.service
sudo sed -i "s|User=deploy|User=$(whoami)|g" /etc/systemd/system/linear-*.service

sudo systemctl daemon-reload
sudo systemctl enable --now linear-clone.service

echo "==> Waiting for backend health (up to 90s)..."
for i in $(seq 1 45); do
    if curl -sf http://localhost:8080/healthz >/dev/null 2>&1; then
        echo "✅ Backend healthy!"
        break
    fi
    sleep 2
done

echo ""
echo "============================================================"
echo "✅ Installation complete!"
echo "============================================================"
echo ""
echo "Visit: https://${DOMAIN}"
echo "(First load: 30-60s while Caddy fetches TLS cert)"
echo ""
echo "Default login: admin@local / password"
