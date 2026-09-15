# Box inventory — measured 2026-09-03

Two boxes. **Sydney is imagineering, Melbourne is enspyr** — but neither is purely one tenant, and that is the first thing to know.

**Regenerate with `./scripts/inventory-boxes.sh`.** Do that rather than trusting the numbers below. `CLAUDE.md`'s service tables drifted three times in the week this was written; a stale inventory is worse than none because it gets believed.

---

## Sydney — `149.118.69.221` (imagineering)

**4 vCPU · 24 GB RAM · 193 GB disk**

| | |
|---|---|
| memory | **5.8 GB used**, 17.7 GB available — container RSS sums to ~6.1 GB |
| disk | **67 GB used, 127 GB free (35%)** |
| `/var/lib/docker` | **72 GB** |
| containers | **41 running** |

### Where the 72 GB goes

| | size | reclaimable |
|---|---|---|
| Images (135, 37 active) | 32.95 GB | 15.7 GB (47%) |
| **Build cache** (442 entries) | **26.66 GB** | **12.64 GB** |
| Local volumes (65, 33 active) | 4.44 GB | 846 MB |
| Containers (43) | 152 MB | — |

**~28 GB is reclaimable** and over half of it is build cache from images built on the box. Not urgent at 127 GB free, but it is the single biggest lever if that changes, and it is a direct cost of the build-on-the-box deploy model that `claude-tasks#2937` proposes replacing.

### Services by tenant

| Tenant | Services |
|---|---|
| **imagineering** | outline (+postgres, redis, minio) · kanbn (+postgres) · radicale · matrix: continuwuity, 4 mautrix bridges, relay-bot, 4 aiko-* · dreamfinder · dreamfinder-avatar · lyra-avatar · contact · familiars · symposium · notify · claudius · claude-shim · brief-service · daemon-service · livekit (+redis) · caddy · aiko-chat-island (4) |
| **enspyr** | `realm-token-server` — `ghcr.io/enspyrco/realm-token-server:0.4.0` |
| **tech-world** | tw-clawd · tw-gremlin |
| **downstream** (guest) | img-downstream-server, plus 7 `downstream-*` systemd units |
| **call-on-clare** (guest) | callonclare-n8n (+postgres) — **vhost dangling, `claude-tasks#3845`** |

### Top memory consumers

| container | RSS | % |
|---|---|---|
| **`notify`** | **1.435 GiB** | **6.13%** |
| imagineering-outline | 540 MiB | 2.25% |
| imagineering-outline-minio | 475 MiB | 1.98% |
| tw-gremlin | 348 MiB | 1.45% |
| dreamfinder-avatar | 318 MiB | 1.33% |
| callonclare-n8n | 297 MiB | 1.24% |
| lyra-avatar | 296 MiB | 1.24% |
| tw-clawd | 289 MiB | 1.21% |
| matrix-mautrix-signal-1 | 288 MiB | 1.20% |
| matrix-continuwuity-1 | 264 MiB | 1.10% |

> **`notify` is an outlier and probably a defect.** It is a small Telegram-send proxy — POST a JSON body, forward it — and it is holding **1.4 GB**, more than the wiki, the object store and the homeserver combined, and ~23% of all container memory on the box. Nothing about its job justifies that. Worth a look before it is worth an alert.

### Not containers

`ubuntu`'s crontab runs 7 watchers (disk, backup-recency, cert-expiry, oci-instance, email-health, oci-provision retry, amanda-oci). `nick`'s runs self-healer (22:00) and `scribe/run-breath.sh` (every 10 min). `/etc/cron.d`: backup, docker-watchdog, keep-alive, health-check + 3 downstream. Units: `embodied-agent-brain.service`, `live-game.service`, 7 `downstream-*`.

Largest app dirs: `scribe` 1.3 GB · `dreamfinder-avatar` 956 MB · `lyra-avatar` 368 MB.

**23 Caddy vhosts**, all `*.imagineering.cc` except `n8n.callonclare.com.au`.

---

## Melbourne — `158.179.17.233` (enspyr)

**4 vCPU · 24 GB RAM · 48 GB disk**

| | |
|---|---|
| memory | **7.9 GB used**, 15.7 GB available |
| disk | **39 GB used, 9.3 GB free (81%)** |
| containers | **5 running** |

> **It uses MORE memory than Sydney (7.9 GB vs 5.8 GB) while running 5 containers instead of 41.** Container RSS here totals ~180 MiB, so essentially all of it is non-Docker — other users' work, or something unaccounted. Worth understanding before planning capacity.

### The disk trap

`docker system df` reports **9.0 GB of images**, but `du /var/lib/docker` shows only **1.7 GB**. Both are right: this box runs **Docker 29 with the containerd image store**, so images live in **`/var/lib/containerd` (8.6 GB)**. Measuring `/var/lib/docker` alone understates Docker's footprint ~5×.

| | |
|---|---|
| `/var/lib/containerd` | 8.6 GB |
| `/var/lib/docker` | 1.7 GB |
| `/home` | **22 GB** |

`/home` breakdown: **`ubuntu` 14 GB · `meghana` 6.9 GB** · adarsha 693 MB · nick 467 MB · ascendbuild 5.7 MB · opc, andy negligible.

Reclaimable from Docker is only ~1.3 GB (677 MB images + 654 MB build cache). **The space is in `/home`, and it is not yours to reclaim** — see below.

### Services by tenant

| Tenant | Services |
|---|---|
| **enspyr** | `aiko-chat-island-1`, `aiko-chat-1`, `aiko-registrar-1` — all `ghcr.io/nickmeinhold/aiko-chat-island:0.9.2` · `aiko-mosquitto-1` · `livekit` (`v1.13.5`) |
| **enspyr (host services)** | `haproxy` — holds **:443**, terminates `turn.enspyr.co`, forwards to Caddy via PROXY-protocol · `caddy` v2.11.4 on `:8443` serving **`chat.enspyr.co`, `livekit.enspyr.co`, `turn.enspyr.co`** · `haproxy-cert-sync.timer` |
| **ascend / other** | `ascend-cage-nft.service` (inactive) |
| shared | nightly 04:20 cron: `backup-aiko-island-standalone.sh aiko-island-enspyr` |

### This box is shared with other people

`/home` holds **seven accounts** — adarsha, andy, ascendbuild, meghana, nick, opc, ubuntu — and `meghana` has interactive logins as recently as 2026-08-12 from a fixed IP.

**Consequences for `claude-tasks#3849` (Kan + Outline here):**
- It is **not a green field.** An earlier survey reported "0 containers" because `docker ps` ran as `nick`, who is not in the `docker` group — `permission denied` and an idle box produce the same empty output.
- **There is already a reverse proxy chain**, HAProxy → Caddy. Standing up another Caddy on :443 would collide with a live one.
- `enspyr.co` DNS already resolves and already has certificates.
- Adding two Postgres, Redis and MinIO onto **9.3 GB free**, on a machine other people are actively using, is a conversation before it is a deploy.

---

## Cross-cutting

- **Both boxes run `caddy` v2.11.4** — Sydney's upgraded itself during a deploy on 2026-09-03 because `caddy:2-alpine` is an unpinned minor tag (`claude-tasks#3729`).
- **Neither box's `imagineering-outline` / `imagineering-kanbn` is governed by this repo's compose files.** Sydney's run from hand-managed `~/apps/imagineering-*` stacks; `deploy-to.sh` refuses those targets on purpose. `claude-tasks#3842`.
- The old GCP host `34.40.229.206` is **unreachable** (SSH times out) — it can probably be written off, but that has not been confirmed with the provider.
