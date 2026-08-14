# cd-bus — design notes

Reactive, secure-by-direction continuous deployment for a self-hosted fleet.
When CI publishes a new container image, the running container updates itself in
seconds — and the host never opens an inbound port, never mounts the Docker
socket, and never holds a credential more powerful than *"pull a public image."*

This document is the **why**. For routes, tokens, and the operational runbook,
see [README.md](README.md); for the fleet subscriber template, see
[fleet/README.md](fleet/README.md).

---

## The failure mode is silence, not latency

The design follows from what actually goes wrong on a self-hosted fleet, not from
what is theoretically slow. Two failure *classes* motivate every choice here:

- **A container auto-updater crash-loops and stops deploying, silently.** A
  daemon API mismatch after a Docker upgrade is enough: the updater process is
  still "running," but the thing it exists to do is dead, and it emits no signal
  — no log line, no alert, just an absence of deploys.
- **A scheduled reconciler exits non-zero every night while its alerts are
  dropped.** A cron that lacks the bot token in its environment fails *open* into
  silence — the consistency check it runs can be blind for weeks and nothing says
  so.

Both share one shape:

> The mechanism reports healthy while its purpose is broken, and the failure
> produces no signal.

Any CD design that does not make a **dead deployer observable** is solving the
wrong problem. That is why observability, not latency, sets the priority order.

## Design priorities

Ranked in the order the evidence demands — latency is real, but it is fourth.

| # | Priority | Why it ranks here |
|---|----------|-------------------|
| 1 | **Observability** | The gap that bites hardest and quietest. Every deploy *and every dead subscriber* must emit a signal a human sees. |
| 2 | **Resilience / self-heal** | A deploy must survive the host being offline at trigger time. Eventual consistency is non-negotiable; strict timeliness is not. |
| 3 | **Security / blast radius** | Minimise resident privilege and inbound surface. A socket-mounting updater is a latent host compromise. |
| 4 | **Latency** | What "reactive" optimises. Real, but for backend services a sub-minute floor is almost always enough. |
| 5 | **Fleet fit** | Dozens of containers already on compose + systemd. Build one capability every service can ride, not one paradigm per service. |

## Architecture

```
  GitHub Actions (per service)            Cloudflare Worker           OCI host (outbound-only)
  ┌──────────────────────────┐  POST     ┌──────────────┐  GET       ┌──────────────────────────┐
  │ build → push GHCR image   │ /publish  │  relay +      │ /events    │ cd-bus-subscriber@svc     │
  │ then: emit image.published │ ────────▶ │  Durable Obj  │ ◀════ SSE ═│  curl -N, deploy on event │
  │ {service, sha, digest, …}  │           │ (retains last │  (held by  │   → compose pull <digest> │
  └──────────────────────────┘           │  event/svc)   │   the host)│   → compose up -d         │
                                           └──────────────┘            ├──────────────────────────┤
                                                  ▲                     │ cd-poll@svc.timer         │
                                                  │  GHCR public images │  backstop: pull+up (idem) │
                                                  └──── host pulls ─────│                           │
                                                                        ├──────────────────────────┤
                                                                        │ journald → Telegram       │
                                                                        │  deploy-fail / sub-down    │
                                                                        └──────────────────────────┘
```

Five parts. The first three **carry** the event; the last two **guarantee** it
lands and that a human finds out if it does not.

### 1. CI emitter — one step appended to each build

After the existing build-and-push step, the workflow POSTs an `image.published`
event to the relay, authenticated by a **publish token** (a relay secret, *not* a
production credential). The digest comes straight from the buildx push output, so
what CI announces is exactly what it built.

### 2. The relay — a Cloudflare Worker + Durable Object

Internet-facing by design, and therefore *stateless and disposable*. `POST
/publish` validates the bearer token and forwards the event to **one Durable
Object instance per service** (`idFromName(service)`). `GET /events/:service` is
the SSE stream the host holds open. The Durable Object **retains the last event
per service**, so a host that reconnects — or was offline — receives the latest
via standard `Last-Event-ID` replay. That retention is the handshake between the
push leg and the poll floor.

Hosting the internet-facing component on serverless infrastructure is the point:
the inbound surface lives somewhere disposable, and the production box stays
strictly outbound. A relay container on the box behind the reverse proxy is a
viable fallback, but then the webhook endpoint is inbound to production — a
smaller surface than SSH, but not zero.

### 3. Per-service subscriber — a templated systemd unit

One unit *template*, instantiated per service with systemd's `@` syntax; the
fleet grows by one line each. The instance name selects both the SSE channel and
the compose directory. The subscriber holds an outbound SSE connection and, on
each event, invokes a fixed, auditable `deploy.sh`: change to the service's
compose directory, pull the announced digest, `up -d`. It can only ever be called
with a service name and a digest — **it cannot run arbitrary commands.** When the
stream drops, the process exits and systemd reconnects; a subscriber that cannot
stay connected becomes a *failed unit*, which is alertable.

### 4. Poll backstop — the resilience floor

A low-frequency per-service timer runs the same idempotent `deploy.sh` — a no-op
when the digest is unchanged. The SSE leg makes deploys *fast*; the poll makes
them *guaranteed*. If the host was offline when an event fired and the retained
replay somehow also missed, the poll converges within one interval. Belt to
SSE's braces.

### 5. Observability — the part that makes a dead deployer loud

Three signals, all surfaced to a human channel via a journald bridge:

- **Deploy outcome** — `deploy.sh` logs success/failure; a forwarder pings on any
  non-zero.
- **Subscriber liveness** — a subscriber entering `failed` (it cannot hold the
  SSE connection) fires an `OnFailure=` alert. *This is the exact class that hides
  for days when a monolithic updater dies.*
- **Staleness watchdog** — if a host has seen neither an event nor the relay
  heartbeat within a window, alert. Catches a wedged relay or a silently-dropped
  subscription.

## The event contract

One JSON shape on the wire — emitted by CI, fanned out by the relay, acted on by
the subscriber. The `digest` is what makes a deploy deterministic: the subscriber
pulls an exact image, not a racing `:latest`.

```json
{
  "event":   "image.published",
  "service": "example-service",
  "image":   "ghcr.io/org/example-service",
  "sha":     "sha-6a38cea",
  "digest":  "sha256:9f2c…",
  "git_sha": "6a38cea1b…",
  "git_ref": "refs/heads/main",
  "run_url": "https://github.com/org/example/actions/runs/123"
}
```

`service` is required (it selects the channel); `digest` is what the subscriber
pulls. Event ids are **monotonic**, not bare timestamps, so id-based dedupe on the
subscriber side is safe even across same-millisecond publishes.

## Security: secure by direction

The core guarantee is geometric: **the host only ever makes outbound connections,
only ever pulls named image digests, and runs one fixed local script.** No
component in the path can execute arbitrary code on the box.

| Component | Holds | Worst-case compromise |
|-----------|-------|-----------------------|
| Production host | nothing inbound; a docker-group user | n/a — it initiates everything outward |
| CI emitter | publish token (relay secret) | trigger a redeploy of an *already-public* image; no shell, no image-push |
| Relay (Worker) | publish token (verify side) | emit deploy events; the host still only pulls GHCR digests in response |
| Image registry | the images | supply-chain risk — pre-existing and orthogonal to the bus |

If the publish token leaks, an attacker can force a redeploy of an image you
already shipped. They cannot push a malicious image (that needs registry write, a
separate credential) and cannot run code on production. Contrast an updater that
mounts `/var/run/docker.sock` into a resident, internet-pulling container: that is
a single compromised `:latest` away from host-root. The bus has **no resident
privileged component at all.**

Token comparison is **constant-time** (each side HMAC'd under a per-call random
key, fixed-length digests compared), so neither token length nor the position of
the first mismatch leaks through response timing.

The two endpoints are deliberately asymmetric on missing auth. `/publish` **fails
closed** when its secret is unbound — an unauthenticated publish would let anyone
inject deploy events. `/events` **falls open** when *its* secret is unbound: an
unauthenticated read leaks no credentials, though it does expose operational
intelligence (image names, shas, deploy cadence), so read-auth is a lockable
control rather than a hard prerequisite. Gating enforcement on the secret being
bound is what lets read-auth roll out across live subscribers without a flag-day
break.

## Alternatives considered

| Approach | Latency | Resilient | Observable | Inbound / prod creds | Verdict |
|----------|---------|-----------|------------|----------------------|---------|
| Socket-mounting auto-updater | ~5 min | silent-fail | none | docker socket = root | the failure this replaces |
| Poll only (timer) | ~5 min (tighter if pushed) | yes | journald | none | fine for a single service |
| Push via CI → SSH | ~0s | lost if offline | CI logs | inbound SSH + prod key | acceptable with a forced-command key |
| Webhook listener on box | ~0s | lost if offline | app logs | inbound HTTP on prod | moves the surface onto production |
| Managed platform (socket agent) | ~0s | yes | UI | resident socket agent | the updater's risk, heavier |
| **SSE deploy bus + poll** | **~0s** | **yes (poll floor)** | **designed in** | **outbound-only** | **recommended for a fleet** |

The forced-command SSH key deserves a note: an `authorized_keys` entry pinned to
`command="…/deploy.sh",no-pty,no-port-forwarding` collapses "CI can root my box"
to "CI can redeploy what CI builds." If you want push without operating a relay,
that is the cheap, honest version. The bus wins when you value *outbound-only* and
*fleet reuse* — the relay earns its keep as a shared capability and as the
observability fix, not as one service's speed-up.

## Design tensions

The trade-offs that stay genuinely open, and how they lean:

- **Does sub-minute latency justify the relay for a single service?** For one
  service a tightened poll likely suffices. The relay's value is *fleet-wide*
  reuse plus the observability guarantee, not raw speed.
- **Per-service channels vs one filtered channel.** One SSE channel filtered by
  `service` is simpler to operate; a Durable Object per service isolates fan-out
  and retention. Start per-service where isolation is cheap; collapse only if
  operational overhead demands it.
- **Could an existing message broker be the transport?** A broker's
  retained-message semantics mirror the Durable Object's last-event retention. But
  SSE-over-HTTPS reuses the existing TLS/reverse-proxy edge with zero new protocol
  surface, which is why it is the default here.
