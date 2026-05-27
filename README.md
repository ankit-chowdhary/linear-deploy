# linear-deploy

Deployment configuration for the self-hosted Linear clone. This repo
contains only Docker Compose, Caddy, systemd units, and shell scripts.
The application source lives in
[`ankit-chowdhary/linear-clone`](https://github.com/ankit-chowdhary/linear-clone)
and is shipped as Docker images on GitHub Container Registry (GHCR).

## What you get

A complete ticketing/issue-tracking workspace, self-hosted on a single
VM:

| Component | Image | What it does |
|---|---|---|
| Backend | `ghcr.io/<you>/linear-clone-backend` | Go API on `:8080`, runs DB migrations on boot |
| Frontend | `ghcr.io/<you>/linear-clone-frontend` | Static React bundle served by nginx |
| Postgres | `postgres:16-alpine` | Application data |
| Redis | `redis:7-alpine` | (Reserved for future caching / rate-limit state) |
| Caddy | `caddy:2-alpine` | TLS termination + reverse proxy, auto Let's Encrypt |

Features that ship in the box:
- Email/password login + per-user JWT sessions (24h)
- Google SSO (admin-configured via the UI, no env vars required)
- Workspace roles: Admin / Member (Members can't see Settings)
- Member management: invite by email, block, delete
- Per-user notification preferences (email + Slack), with admin-editable email templates
- Workspace SMTP config + per-admin Slack incoming webhooks (URLs encrypted at rest with AES-GCM keyed on `JWT_SECRET`)

## Architecture

```
                       Internet
                          │
                       :80, :443
                          ▼
                  ┌──────────────┐
                  │    Caddy     │  ← TLS, auto-cert
                  └──────┬───────┘
                         │
                ┌────────┴────────┐
                ▼                 ▼
        ┌──────────────┐  ┌──────────────┐
        │   frontend   │  │   backend    │
        │  (nginx/React)│  │  (Go :8080)  │
        └──────────────┘  └──────┬───────┘
                                 │
                  ┌──────────────┼──────────────┐
                  ▼              ▼              ▼
            ┌─────────┐    ┌─────────┐
            │postgres │    │  redis  │
            └─────────┘    └─────────┘
```

Everything runs as one Docker Compose stack on a single VM. The
`linear-clone.service` systemd unit calls `docker compose up -d` on
boot so the stack survives reboots without manual intervention.

---

## Fresh-VM deploy

### 0. Prerequisites

- **A VM** running Ubuntu 22.04 LTS, root SSH access, public IPv4.
  2 vCPU + 4 GB RAM is plenty for a small team.
- **A domain** pointing at the VM's public IP. Create an `A` record
  for whatever subdomain you want (e.g. `linear.example.com`) before
  starting the install — Caddy needs DNS resolution to obtain the
  TLS certificate.
- **A GitHub account** with read access to the GHCR images
  (`ghcr.io/<you>/linear-clone-backend` and `linear-clone-frontend`).
  If the source repo is private, you also need a Personal Access
  Token with `read:packages` scope —
  [Settings → Developer settings → Personal access tokens](https://github.com/settings/tokens)
  → Generate new token → tick `read:packages` only → copy the token.

### 1. Bootstrap the VM (as root)

SSH into the VM as root. Pull this repo down (it's tiny) and run the
bootstrap script:

```bash
ssh root@<your-vm-ip>
apt-get update && apt-get install -y git
git clone https://github.com/ankit-chowdhary/linear-deploy.git /tmp/linear-deploy
cd /tmp/linear-deploy
sudo bash bootstrap.sh
```

What it does (idempotent — safe to re-run):
- Removes any nginx/apache that came pre-installed (would conflict with Caddy on :80)
- Installs Docker Engine + Compose v2 from Docker's official apt repo
- Creates a non-root `deploy` user with `sudo` for systemd
- Hardens SSH (disables root login, restricts to `deploy`)
- Configures `ufw` (allows 22, 80, 443) and enables `fail2ban`
- Adds a 2 GB swap file
- Generates a random password for the `deploy` user and saves it to `/root/deploy-user-password.txt`

When it finishes, **note the password** (or copy your SSH key into
`~deploy/.ssh/authorized_keys`).

### 2. Install the app (as the deploy user)

```bash
ssh deploy@<your-vm-ip>          # password from /root/deploy-user-password.txt
git clone https://github.com/ankit-chowdhary/linear-deploy.git ~/linear-clone
cd ~/linear-clone
bash install.sh
```

`install.sh` prompts you for:

| Prompt | What to enter |
|---|---|
| GitHub username | The account whose PAT you'll use for GHCR login |
| Image namespace | The org/user that owns the GHCR images (likely the same) |
| GitHub PAT | The `read:packages` PAT you generated |
| Domain | `linear.example.com` (must already resolve to this VM) |
| Let's Encrypt email | An email Caddy can use for ACME notifications |

What it does:
- Generates strong random secrets: `pg_password`, `jwt_secret`, `report_api_key` (saved to `~/linear-clone/secrets/*.txt`, `chmod 600`)
- Writes `~/linear-clone/.env.prod` with the secrets + your domain
- Logs into GHCR with the PAT
- Pulls all five images
- Installs systemd units (`linear-clone.service`, `linear-backup.service` + `.timer`)
- Starts the stack (Postgres comes up healthy first, then Redis, then backend — which runs migrations 001..00N on its first boot — then frontend, then Caddy)
- Waits up to 90s for backend `/healthz` to return `ok`

If everything went green, browse to **https://your-domain.com**. The
first page load takes 30–60 seconds while Caddy issues the TLS
certificate.

### 3. First sign-in

The seed migration creates one bootstrap admin:

- **Email:** `admin@local`
- **Password:** `password`

This is **intentionally insecure** — it's only meant to get you in
the door. Do the following immediately:

1. Sign in as `admin@local`.
2. **Settings → Administration → Email** — configure your SMTP server.
   Save and click **Send test email** to verify delivery.
3. **Settings → Administration → Members → Invite member** — invite
   yourself with your real email address (Admin role).
4. Open your inbox, click the invite link, set a password.
5. Sign out, sign back in as your real account.
6. **Settings → Administration → Members** — find `admin@local`,
   click the **Block** icon (and/or **Delete**) so nobody else can
   ever sign in with the seeded credentials.

After this point you have a workspace with no default-password
backdoor.

### 4. Optional: post-install configuration

All of these live under **Settings → Administration**.

#### Slack notifications
**Slack** page. Each admin can paste their own incoming-webhook URLs
(from `api.slack.com/apps` → Incoming Webhooks → Add to channel).
Per-user notification preferences live under **Settings →
Notifications → Slack** and gate which events post.

#### Google Single Sign-On
**Single Sign-On** page. The page shows you the **Redirect URI** to
paste into your Google OAuth client. Walk-through:

1. Open https://console.cloud.google.com/apis/credentials in a new tab.
2. Create a project → configure OAuth consent screen (External, fill in basics, add yourself as a test user).
3. **+ CREATE CREDENTIALS → OAuth client ID → Web application**.
4. **Authorized redirect URIs** → paste the URI shown on the SSO page (`https://your-domain/api/v1/auth/google/callback`).
5. Copy the **Client ID** and **Client Secret** that Google shows you.
6. Back in Voiger: paste both, optionally restrict to an email-domain whitelist, decide whether unknown Google emails should auto-create Member accounts, **Enable** → **Save**.
7. Sign out → login page now shows **Sign in with Google**.

The Client Secret is AES-GCM encrypted at rest with a key derived
from `JWT_SECRET` — the DB alone can't reveal it.

#### Email templates
**Settings → Administration → Email** → scroll to **Templates**. Four
templates ship seeded:

- `invite` — sent to invitees
- `invite_accepted` — sent to the inviter when accepted
- `issue_assigned` — sent to the assignee on creation/reassignment
- `status_changed` — sent to the assignee on status changes

Each one is a Go `text/template`. The available variables are shown
inline above the editor (e.g. `{{.InviterName}}`, `{{.URL}}`). Edits
take effect immediately for the next outgoing message.

---

## Day-2 operations

### Updates (rolling out a new app version)

The pipeline is **push to `main` on `linear-clone` → GitHub Actions
builds + pushes new images → pull on the VM**.

```bash
ssh deploy@your-vm
cd ~/linear-clone
bash scripts/deploy.sh
```

`scripts/deploy.sh`:
1. `git pull` for any infra config changes (this repo)
2. Pulls fresh backend + frontend images from GHCR
3. Recreates backend first, waits for `/healthz` (up to 60s), then frontend
4. Prunes dangling images older than 7 days

**Migrations are automatic.** The backend embeds `internal/migrations/*.sql`
and runs unapplied ones on every startup, tracked in the
`schema_migrations` table.

### Logs

```bash
bash ~/linear-clone/scripts/logs.sh                  # all services
bash ~/linear-clone/scripts/logs.sh backend          # one service
bash ~/linear-clone/scripts/logs.sh -f frontend      # follow
```

### Health snapshot

```bash
bash ~/linear-clone/scripts/health.sh
```

Prints `docker compose ps`, disk free, memory free, and the `/healthz`
response.

### Backups (already configured)

`bootstrap.sh` installs `linear-backup.timer` which fires
`linear-backup.service` → `scripts/backup.sh` daily. Each run produces
`~/linear-clone/backups/linear-YYYYMMDD-HHMMSS.dump.gz` (Postgres
custom-format dump, gzipped). Files older than 14 days are deleted.

**Restoring** (off-host disaster recovery is your responsibility —
copy the dump file elsewhere):

```bash
cd ~/linear-clone
set -a; source .env.prod; set +a
gunzip -c backups/linear-20260601-030000.dump.gz | \
  docker compose -f docker-compose.prod.yml exec -T postgres \
  pg_restore -U "$PG_USER" -d "$PG_DB" --clean --if-exists
docker compose -f docker-compose.prod.yml restart backend
```

---

## File layout

```
linear-deploy/
├── README.md                  ← this file
├── TROUBLESHOOTING.md
├── Caddyfile                  ← reverse proxy + TLS
├── docker-compose.prod.yml    ← five services, no source baked in
├── bootstrap.sh               ← root, one-time VM prep
├── install.sh                 ← deploy user, one-time app install
├── digests.lock               ← (optional pinning, not enforced yet)
├── scripts/
│   ├── deploy.sh              ← rolling update
│   ├── backup.sh              ← pg_dump daily
│   ├── logs.sh                ← tail compose logs
│   └── health.sh              ← status snapshot
└── systemd/
    ├── linear-clone.service   ← brings the stack up on boot
    ├── linear-backup.service  ← runs scripts/backup.sh
    └── linear-backup.timer    ← daily schedule
```

The application source repo
([`linear-clone`](https://github.com/ankit-chowdhary/linear-clone))
contains everything else — `backend/`, `frontend/`,
`backend/internal/migrations/*.sql`, the GitHub Actions workflow that
builds the images.

---

## Troubleshooting

See **[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)** for the common
failure modes — pre-installed nginx blocking port 80, the old Python
`docker-compose` v1 ContainerConfig bug, missing
`docker-compose-plugin`, etc.

Quick failures and fixes:

| Symptom | Likely cause | Fix |
|---|---|---|
| First page load hangs / `connection refused` | Caddy can't get a cert (DNS not resolving yet) | Wait 1–2 min after DNS change, `docker compose logs caddy` to confirm |
| `unable to get image 'ghcr.io/...': denied` | PAT lacks `read:packages` or wrong namespace | Re-issue PAT with `read:packages`, `docker login ghcr.io -u <you>` |
| Backend log says `db ping failed` | `.env.prod` has wrong `PG_PASSWORD` (regenerated by mistake) | Restore from `backups/`, regenerate everything matched, or `docker compose down -v && bash install.sh` |
| Members page is empty after fresh deploy | You haven't invited anyone yet — only `admin@local` exists | Use the Invite member button |
| Can't see Settings as a Member | Working as intended — only Admins see Settings | Have an Admin promote the role |
| Lost the admin@local password and there's no other admin | The default is `admin@local` / `password`; if you changed it without keeping a copy, see "Reset bootstrap admin" below |

### Reset bootstrap admin

If you've lost access to all admin accounts:

```bash
ssh deploy@your-vm
cd ~/linear-clone
set -a; source .env.prod; set +a
docker compose -f docker-compose.prod.yml exec -T postgres \
  psql -U "$PG_USER" -d "$PG_DB" <<'SQL'
UPDATE users
SET password_hash = '$2a$10$ymaLIje05TC4ok8CD3UanuCfZzQAGFIHnH0B1oYBahIneUSrSRkoy',
    role          = 'admin',
    status        = 'active'
WHERE email = 'admin@local';
SQL
```

(The hash is `bcrypt("password")` — same as the original seed.)

Then sign in as `admin@local` / `password`, promote your real
account back to Admin, and re-block `admin@local`.
