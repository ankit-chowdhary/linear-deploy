# Troubleshooting

## "address already in use" when starting Caddy

Some cloud Ubuntu images ship with nginx or apache2 pre-installed
and running. `bootstrap.sh` removes these automatically, but if you're
re-installing, run:

```bash
sudo systemctl stop nginx apache2 2>/dev/null || true
sudo apt-get remove -y --purge nginx nginx-common nginx-core apache2
```

## `docker compose` says "unknown command" / `apt` can't find `docker-compose-plugin`

This happens on VPSes where Ubuntu's own `docker.io` package was
installed first — the Compose v2 plugin is only in Docker's official
apt repo, not Ubuntu's. Re-running `bootstrap.sh` (as root) fixes it
because the updated bootstrap always (re)adds Docker's apt repo.

If you can't re-run bootstrap, apply just the targeted fix:

```bash
# 1. Remove Ubuntu's docker packages
sudo apt-get remove -y --purge docker docker.io docker-compose containerd runc

# 2. Add Docker's official apt repo
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list

# 3. Install Docker Engine + Compose v2
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# 4. Verify
docker compose version
```

## `docker-compose up` fails with `KeyError: 'ContainerConfig'`

You're on the legacy Python `docker-compose` v1.29.2 from Ubuntu's
repos. It has a known bug when recreating containers whose image
was produced by a newer Docker engine. Fix:

1. Install Compose v2 using the steps above.
2. From now on use `docker compose` (space), never `docker-compose`
   (hyphen). All scripts in this repo (`scripts/deploy.sh`,
   `scripts/backup.sh`, etc.) already use v2.

If you need to recover containers that are stuck mid-recreate before
v2 is installed, you can manually `stop`/`rm` them with the legacy
binary:

```bash
docker-compose -f docker-compose.prod.yml stop backend frontend
docker-compose -f docker-compose.prod.yml rm -f backend frontend
# then install v2 per the section above, and:
docker compose -f docker-compose.prod.yml up -d
```
