# Make the Dead Deployer Loud

*Reactive, secure-by-direction continuous deployment — and why the failure that matters is silence, not slowness.*

Here's a continuous-deployment pattern where the host updates itself within seconds of a merge — and never opens an inbound port, never mounts the Docker socket, never holds a credential stronger than "pull a public image." Most CD is sold on speed. The one thing this one refuses to do is fail *quietly*: a dead deployer is loud by construction.

I built it because the last one wasn't.

For thirteen days, nothing deployed. The auto-updater ran the whole time — green process, clean logs, zero errors. Every merge to `main` built an image, pushed it, and stopped there. The containers never came up, and nothing said so: no alert, no red check, just a silent, widening gap between what the repo claimed was running and what actually was. We found out by accident a week later, when someone went looking for a change that wasn't there.

That's the real bug — not "deploys are too slow," but "a deploy system can be stone dead and *feel* completely healthy." Everything below follows from fixing that.

## Contents

- [The wound was silence, not slowness](#the-wound-was-silence-not-slowness)
- [Getting the priorities in the right order](#getting-the-priorities-in-the-right-order)
- [Secure by direction: the arrows only point out](#secure-by-direction-the-arrows-only-point-out)
- [The five parts](#the-five-parts)
- [The security payoff](#the-security-payoff)
- [Why not the obvious alternatives](#why-not-the-obvious-alternatives)
- [What it honestly costs](#what-it-honestly-costs)
- [The lesson](#the-lesson)

## The wound was silence, not slowness

Two failures on the same self-hosted fleet motivated this, and neither was about latency.

The first was the thirteen-day one. A container auto-updater — the popular kind that watches a registry and pulls new images for you — crash-looped after a routine Docker upgrade bumped the daemon's API version out from under it. The updater's client spoke one API version; the daemon now spoke another; every reconcile attempt threw and the updater moved on. It never deployed anything again, and it never told anyone. The process stayed up. To every health check that mattered, it looked fine.

The second was quieter and lasted longer. A nightly reconciliation job — the kind that checks your database against your backups and screams if they've diverged — started exiting non-zero every single night. Its alerts were supposed to fire to a chat channel, but the cron entry that ran it was missing the bot token in its environment, so the "scream" step failed *before it could scream*. The consistency check was blind for a month, and the thing that was supposed to notice was blind to itself.

Stare at those two side by side and the shared shape jumps out:

> The mechanism reports healthy while its purpose is broken, and the failure produces no signal.

This is the specific, nasty failure class of any automation you're not looking at directly: it doesn't crash loudly, it just quietly stops meaning anything. A crash you'll catch — something restarts, something pages. It's the *silent* stop that eats weeks, because every dashboard you built is measuring the wrong thing (is the process up?) instead of the thing you care about (did the work actually happen?).

So the first design principle wrote itself: **any continuous-deployment system that doesn't make a dead deployer observable is solving the wrong problem.** Speed is a nice-to-have. Not-lying-to-you is the requirement.

## Getting the priorities in the right order

It's worth being explicit about the ranking, because most CD tools are sold on the fourth item and quiet about the first.

| # | Priority | Why it ranks here |
|---|----------|-------------------|
| 1 | **Observability** | The gap that bit twice, and bit quietly. Every deploy *and every dead subscriber* must emit a signal a human sees. |
| 2 | **Resilience** | A deploy must survive the host being offline at trigger time. Eventual consistency is non-negotiable; strict timeliness isn't. |
| 3 | **Security / blast radius** | Minimise resident privilege and inbound surface. A socket-mounting updater is a latent host compromise. |
| 4 | **Latency** | What "reactive" optimises. Real, but for backend services a sub-minute floor is almost always enough. |
| 5 | **Fleet fit** | Dozens of containers already on compose and systemd. Build one capability every service can ride, not one paradigm per service. |

If your ranking really does put latency first — you're deploying a trading system, a live demo, something where seconds are money — you'll make different calls than I did, and that's correct. But be honest about whether you're optimising for genuine speed or just for the *feeling* of speed. Most backend services are fine reaching production in under a minute. Almost none are fine silently not reaching it at all.

## Secure by direction: the arrows only point out

Here's the whole system on one line, and the one line is the security model:

**The production host only ever makes outbound connections, only ever pulls named image digests, and runs exactly one fixed local script.**

That sentence is doing enormous work. It means the box has nothing to attack from the outside — no inbound webhook, no SSH-for-deploys, no management agent listening on a port. It means the "deployer" can't be tricked into running arbitrary code, because the only thing it can do is pull a specific image and run a specific script. The geometry *is* the guarantee.

```
  GitHub Actions (per service)          Cloudflare Worker          Host (outbound-only)
  ┌───────────────────────────┐  POST   ┌──────────────┐  GET      ┌───────────────────────┐
  │ build → push image         │ ──────▶ │  relay +      │ ◀═ SSE ══│ subscriber (curl -N)   │
  │ then: announce image        │        │  Durable Obj  │ (held by  │  deploy on event:      │
  │ {service, digest, sha, …}   │        │ (keeps last   │  the host)│   pull <digest> → up   │
  └───────────────────────────┘        │  event/svc)   │           ├───────────────────────┤
                                         └──────────────┘           │ poll timer (backstop)  │
                                                ▲    registry        ├───────────────────────┤
                                                └──── host pulls ────│ journald → chat alert  │
                                                                     └───────────────────────┘
```

Compare that to the auto-updater it replaced, which mounted the Docker socket — `/var/run/docker.sock` — into a resident, internet-pulling, third-party container. That socket is root on the host. One compromised `:latest` tag and the game is over. The tool that was silently failing to deploy was *also*, the whole time, the single biggest attack surface on the machine. We deleted both problems with the same design.

## The five parts

Five components. The first three *carry* the deploy event; the last two *guarantee it lands* and that a human finds out if it doesn't.

**1. The CI emitter.** After the build-and-push step your pipeline already has, add one step that POSTs an announcement to the relay: "service X, image digest `sha256:…`, here's the git sha and the run URL." It's authenticated with a *publish token* — a secret for talking to the relay, deliberately **not** any kind of production credential. The digest comes straight out of the build, so what CI announces is exactly the bytes it just built. No `:latest` races.

**2. The relay.** A small, stateless, internet-facing service — we used a Cloudflare Worker with a Durable Object, but the shape matters more than the vendor. `POST /publish` verifies the token and hands the event to one Durable Object *per service*. `GET /events/:service` is a Server-Sent Events stream the host holds open. Crucially, the Durable Object **retains the last event per service**, so a host that reconnects — or was offline when the event fired — gets the latest one immediately via standard SSE `Last-Event-ID` replay. Putting the only internet-facing piece on disposable serverless infra is the entire point: the exposed surface lives somewhere stateless and throwaway, and the production box stays strictly outbound.

**3. The subscriber.** On each host, one tiny outbound-only process per service — really just `curl -N` holding the SSE stream open. When an event arrives, it calls a fixed, auditable `deploy.sh`: change to the service's compose directory, pull the announced digest, bring it up. That script is the *only* thing it can invoke, and it can only invoke it with a service name and a digest. There is no code path from "attacker controls the event" to "attacker runs a command." When the stream drops, the process exits and systemd restarts it — and a subscriber that *can't* hold the connection becomes a **failed unit**, which is a thing you can alert on. Hold that thought.

**4. The poll backstop.** A low-frequency timer runs the same idempotent `deploy.sh` on a schedule — a no-op when the digest hasn't changed. The SSE leg makes deploys *fast*; the poll makes them *guaranteed*. If the host was offline when an event fired and somehow the retained-event replay also missed it, the poll converges within one interval anyway. Belt and braces. You lose the fast path gracefully — latency degrades to the poll floor, it never becomes an outage.

**5. Observability — the part that makes item 3's "hold that thought" pay off.** Three signals, all forwarded to a human channel:

- **Deploy outcome.** `deploy.sh` logs success or failure; a forwarder pings on any non-zero exit. You see every deploy, and every *failed* deploy louder.
- **Subscriber liveness.** A subscriber that enters the `failed` state — it genuinely cannot hold the SSE connection — fires an alert. *This is the exact class of failure that hid for thirteen days.* A dead deployer is now a red unit and a message, not an absence.
- **Staleness watchdog.** If a host hasn't seen either an event or the relay's heartbeat within a window, it alerts. That catches a wedged relay or a silently-dropped subscription — the "everything looks fine but nothing is flowing" state, made visible.

The auto-updater had none of these. It couldn't; it was a black box you pointed at a registry and hoped. The whole reason to build the deploy path out of small, legible pieces is that each seam becomes a place you can *watch*.

## The security payoff

Lay out who holds what, and what the worst case is if each piece is fully compromised:

| Component | Holds | Worst-case compromise |
|-----------|-------|-----------------------|
| Production host | nothing inbound; a docker-group user | n/a — it initiates everything outward |
| CI emitter | a publish token (relay secret) | force a redeploy of an *already-public* image; no shell, no image-push |
| Relay | the publish token (verify side) | emit deploy events; the host still only pulls signed digests in response |
| Registry | the images | supply-chain risk — pre-existing, and orthogonal to this system |

Read the CI-emitter row twice, because it's the one people worry about. If the publish token leaks, what can an attacker *do*? Announce a deploy event. That makes hosts pull an image that was already built and already public and run it. They cannot push a malicious image — that needs registry write, an entirely separate credential — and they cannot run arbitrary code on your box. The blast radius of your most-exposed secret is "force a redeploy of something you already shipped." That's a property worth designing for.

Two smaller touches that matter. Token comparison is **constant-time**, so neither the length of a token nor the position of the first wrong byte leaks through response timing. And the two endpoints fail in deliberately *opposite* directions when their secret is missing: `/publish` **fails closed** (no token bound → reject everything, because an open publish endpoint lets anyone inject deploys), while `/events` **fails open** (no token bound → serve the stream, because an open read leaks no credentials — only operational trivia like image names and cadence). That asymmetry is what lets you roll read-authentication out across live subscribers gradually, without a flag-day where everything 401s at once.

## Why not the obvious alternatives

| Approach | Latency | Resilient | Observable | Inbound / prod creds | Verdict |
|----------|---------|-----------|------------|----------------------|---------|
| Socket-mounting auto-updater | ~5 min | silently fails | none | Docker socket = root | the failure this replaces |
| Poll only (a timer) | ~5 min | yes | logs | none | genuinely fine for one service |
| Push via CI → SSH | ~0s | lost if offline | CI logs | inbound SSH + a prod key | okay with a locked-down forced-command key |
| Webhook listener on the box | ~0s | lost if offline | app logs | inbound HTTP on production | moves the attack surface onto prod |
| Managed platform w/ agent | ~0s | yes | a UI | resident socket agent | the updater's risk again, heavier |
| **SSE bus + poll floor** | **~0s** | **yes** | **designed in** | **outbound-only** | **the one we built** |

One honest callout: the **poll-only** row is not a joke. If you run a single service, a tightened polling timer with its exit code wired to an alert gives you most of what matters here for a fraction of the moving parts. This bus earns its complexity as a *fleet* capability — one relay, one subscriber template, every service rides it — and as the observability fix. If you have one box and one app, start with the poll and a good alert, and come back for the bus when you have five.

And the **forced-command SSH key** row deserves respect too. An `authorized_keys` entry pinned to `command="…/deploy.sh",no-pty,no-port-forwarding` collapses "CI can root my box" down to "CI can redeploy what CI builds." If you want push-speed without operating a relay, that's the cheap, honest version — you just accept an inbound door and a key living in CI.

## What it honestly costs

No design is free, and the trade-offs here are real:

- **You now operate a relay.** It's small and stateless, but it's a thing that can break, and when it does your fast path is gone until it's back (the poll floor keeps you *deploying*, just slowly). A relay you don't monitor is just a new silent-failure surface — so it gets the same staleness watchdog as everything else. Physician, heal thyself.
- **Per-service isolation vs. one channel.** We run a Durable Object per service, which isolates fan-out and retention cleanly but multiplies instances. A single channel filtered by service name is simpler to operate and fine until load says otherwise. Start wherever isolation is cheap.
- **It's more parts than a cron.** Five components is five things to understand. The justification is that each part is small and *legible* — and legibility is exactly what the black-box updater lacked. You're trading a small amount of "one thing to deploy" for a large amount of "I can see where it broke."

## The lesson

The bug wasn't slowness, and the fix wasn't speed. The bug was a machine that could fail completely while looking perfectly healthy, and the fix was to build the deploy path out of pieces small enough that each one can be *watched* — and then to actually watch them, including the watcher.

If you take one thing from this: go look at your own automation — your CD, your backups, your reconcilers, your cron jobs — and ask not "is the process running?" but "if this silently stopped doing its job, how long until I'd know?" If the honest answer is "weeks," you have a thirteen-day silence waiting to happen. The point of all of this is a single, boring guarantee:

**A dead deployer should be loud.**
