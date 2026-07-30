# imagineering-infra

Infrastructure monorepo for self-hosted services.

## Services

| Service | Description | URL |
|---------|-------------|-----|
| [Kan.bn](./kanbn/) | Kanban boards (Trello alternative) | kan.imagineering.cc |
| [Outline](./outline/) | Team wiki (Notion alternative) | outline.imagineering.cc |
| MinIO | S3-compatible file storage | storage.imagineering.cc |
| [Caddy](./caddy/) | Reverse proxy with automatic HTTPS | - |
| [Radicale](./radicale/) | CalDAV/CardDAV server | dav.imagineering.cc |
| downstream-server | Guest service — not part of Imagineering. Ops live in [nickmeinhold/downstream `deploy/oci`](https://github.com/nickmeinhold/downstream/tree/main/deploy/oci); this repo keeps only the platform bits: the Caddy route for api.downstream-storage.cc, `scripts/lib/telegram.sh`, and generic shared-host hygiene (health-check/watchdog cover it as one container among many) (shared alert helper its host scripts source from `/opt/scripts/lib/`) | api.downstream-storage.cc |

## Infrastructure

| Provider | Status | IP | Cost |
|----------|--------|-----|------|
| OCI (Oracle Cloud) | **Active** | 149.118.69.221 | Free tier (200 GB disk, 4 OCPU, 24 GB RAM) |

## Architecture

```
Internet → Caddy (443/80) → Kan.bn (3013)
                          → Outline (3012)
                          → MinIO (9010)
                          → Radicale (5232)
                          → downstream-server (3018)  [guest service]
```

## Quick Start

### Prerequisites

```bash
brew install sops age yq
```

### 1. Set up encryption key

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# Add public key to .sops.yaml
```

### 2. Deploy services

```bash
./scripts/deploy-to.sh 149.118.69.221 all
```

### 3. Deploying to a different host

The defaults target the Sydney box, so the command above is unchanged. A second
host overrides only what differs, via the environment:

| Variable | Default | What it controls |
|---|---|---|
| `DEPLOY_USER` | `nick` | ssh user on the target host. Also used for file ownership (`/opt/scripts`, the `/etc/imagineering-secrets/*.env` group) and as the cron user. |
| `REMOTE_HOME` | `/home/$DEPLOY_USER` | Where host-side bind-mount sources live — `whisper.cpp`, `piper`, `kokoro`, `~/apps/{site,invite,galaxy}`, ssh deploy keys — and where cron writes logs. |
| `DOCKER_HOST_IP` | `192.168.32.1` | The host's docker bridge gateway, mapped to `host.docker.internal`. Find it with `ip -4 addr show docker0`. |
| `TURN_DOMAIN` | `turn.imagineering.cc` | Hostname on the TURN/TLS certificate LiveKit presents. |
| `EDF_SRC` | `~/git/orgs/imagineering/dreamfinder-avatar` | Local checkout of the avatar app. |

```bash
DEPLOY_USER=<user> DOCKER_HOST_IP=<bridge-gw> TURN_DOMAIN=turn.example.org \
  ./scripts/deploy-to.sh <host> dreamfinder-avatar
```

`<host>` is an IP or an `~/.ssh/config` alias — prefer the alias. Host addresses
are deliberately **not** recorded in this repo; it is public, and an
address-to-service map is reconnaissance. Keep them in your `~/.ssh/config`.

`REMOTE_HOME` follows `DEPLOY_USER`, so setting the user alone is usually
enough. Compose files carry the same defaults inline, and `deploy-to.sh` writes
the resolved values into the deployed `.env` — so a manual `docker compose up`
on the box behaves the same as a scripted deploy.

**A wrong `REMOTE_HOME` fails silently at the Docker layer** — a missing bind
source is created as an empty directory and the container starts anyway. The
avatar deploy therefore preflights all six local-audio mounts on the remote and
aborts before building if any is absent.

## Repository Structure

```
.
├── caddy/                  # Reverse proxy config
├── kanbn/                  # Kan.bn (Trello alternative)
├── outline/                # Outline wiki
├── radicale/               # CalDAV/CardDAV server
├── dreamfinder/    # Signal PM bot (Dreamfinder)
├── backups/                # Backup configuration
├── scripts/
│   ├── deploy-to.sh        # Deployment script
│   ├── backup.sh           # Backup script
│   └── restore.sh          # Restore script
└── .sops.yaml              # SOPS encryption config
```

## Secrets Management

All secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age).

```bash
# Edit encrypted secrets
sops kanbn/secrets.yaml
sops outline/secrets.yaml
```
