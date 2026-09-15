# scripts/host — code that runs on Sydney but is not deployed from here

These scripts were found running on the box on 2026-08-26 with **no copy in any
repository** (inventory: claude-tasks #3512). They are tracked here so the source
exists somewhere other than one container's disk.

> **Reading them as "now repo-authoritative" would be exactly wrong.** Nothing
> deploys these to the paths cron actually invokes. `deploy-to.sh scripts`
> installs the tree to `/opt/scripts/`, so a copy of `docker-watchdog.sh` lands
> at `/opt/scripts/host/docker-watchdog.sh` while root cron keeps running
> `/opt/docker-watchdog.sh`. That is a second copy, which is the same parallel-
> tree condition that hid PR #94 for thirteen days.
>
> The manifest marks them `orphaned` for precisely this reason, and
> `check-run-paths.sh` reports them as drift the moment the two diverge.
> Cutting the schedule over is a human step, tracked on #3482.

| script | runs as | schedule | what it does |
|---|---|---|---|
| `docker-watchdog.sh` | root | `*/15 * * * *` | restarts containers that exited non-zero; skips clean exits so one-shot init containers are not looped |
| `keep-alive.sh` | root | `0 */2 * * *` | burns CPU for 120s so OCI does not reclaim the instance for idleness. **This is the only thing keeping the box.** |
| `release-watch.sh` + `.conf` | nick | *(unscheduled)* | watched upstream releases for outline/radicale/caddy/minio/redis. Its cron entry was deleted 2026-08-26 because it carried a bot token inline, world-readable (#3360). Restoring it means rotating the token and reading it from `/etc/imagineering-secrets/telegram.env`, not re-inlining. |
| `self-healer-run.sh` | nick | `0 22 * * *` | wrapper: sources env, runs `self-healer/src/healer.mjs`, keeps the latest verdict + a capped log |

## The manifest and the check

`run-paths.tsv` maps repo file → running path → honest status
(`deployed` / `orphaned` / `external`). `../check-run-paths.sh` reads it, hashes
both sides, and answers two questions:

1. does each running copy match its repo copy?
2. **does anything on the box run from a path no row claims?**

The second question is the one that matters. It enumerates cron (both crontabs
and `/etc/cron.d`) plus enabled systemd units and reports any target the
manifest does not mention — so a new untracked script appears as a finding
without anyone remembering to add it first. A checker that only knows what it
was told cannot find what nobody knew.

```bash
scripts/check-run-paths.sh            # exit 0 reconciled, 1 drift, 2 could-not-check
```

Exit 2 is deliberately distinct: an ssh failure or an empty remote response is
**not** a pass. It currently exits 1, because two watchers genuinely have
diverged and will keep diverging until #3482 cuts the schedule over. When that
lands, the `orphaned` rows become `deployed` and this goes green — which makes
it a usable acceptance test for that work rather than a report nobody reads.
