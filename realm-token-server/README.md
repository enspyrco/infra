# realm-token-server secrets

Encrypted backup of the runtime `.env` for `realm-token-server` on the OCI box
(`~/apps/realm-token-server/.env`), which was previously the **only** copy.

The ES256 keypair is why this exists. Losing the private key invalidates every
live Realm credential — there is no re-derivation, and re-issuing forces every
signed-in client back through `/exchange`.

## Restore

```bash
sops -d secrets.yaml > /tmp/rts.yaml
python3 - <<'PY' > /tmp/rts.env
import yaml
for k, v in yaml.safe_load(open('/tmp/rts.yaml')).items():
    print(f"{k}={v}")
PY
scp /tmp/rts.env <box>:~/apps/realm-token-server/.env
shred -u /tmp/rts.yaml /tmp/rts.env      # or rm -P on macOS
ssh <box> 'cd ~/apps/realm-token-server && docker compose up -d && docker compose ps'
```

Values are stored **verbatim** as they appear in `.env`, so a restore is
byte-identical. PEM newlines are literal `\n` — `src/index.js` unescapes them at
startup, so do not "fix" them into real newlines.

## Update after a secret rotates

```bash
sops secrets.yaml          # edits in place, re-encrypts on save
```

Then restore to the box as above. Verify with `docker compose ps` showing
`healthy` — the healthcheck hits `/healthz`, and the container refuses to boot
at all if `CORS_ALLOWED_ORIGINS` is missing or malformed.

## Not covered here

The Caddy vhost (`realm-token.imagineering.cc { reverse_proxy localhost:8791 }`)
still lives only in the box's hand-edited Caddyfile. Tracked in
`nickmeinhold/claude-tasks#2830`.
