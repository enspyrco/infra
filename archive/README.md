# archive/

Long-lived artefacts that must survive a box dying, are too small to justify a
storage tier, and cannot be committed in the clear because they contain secrets.

Encrypted with SOPS/age under the same key as every `*/secrets.yaml` in this repo
(`.sops.yaml` covers `archive/*.yaml`). Payloads are base64 inside a single
`archive_b64` key so a binary blob round-trips through SOPS's YAML handling
unchanged.

## Contents

### `xdeca-appdirs-20260902.yaml`

xdeca's per-stack deployment configuration, captured immediately before the
tenant was decommissioned on 2026-09-02.

| | |
|---|---|
| Payload | `xdeca-decommissioned-20260902-appdirs.tar.gz`, 8 KB, 21 entries |
| sha256 (decrypted) | `150479add2748eaf2250c787a2095519047cd28802388d0f895188ecc9da7425` |
| Holds | each stack's `docker-compose.yml`, `.env`, `.env.local`, `secrets.yaml.example`, `.claude/settings.local.json` |

**Why it is here and not in `10xdeca/xdeca-backups`.** That repo holds xdeca's
DATA — `outline.sql`, `kanbn.sql`, `radicale.tar`, `minio.tar.gz`, `gremlin.db` —
verified byte-identical and independently openable on 2026-09-07. It deliberately
does not hold the `.env` files, because they are secrets and that repo stores
plaintext dumps.

The consequence was that **the data had three copies and the configuration had
one**, sitting on `enspyr-syd`'s boot volume. Restoring xdeca from GitHub would
have produced working databases and no record of what they were configured with.
This file closes that gap: it is now in git history, off both boxes, and does not
depend on anyone remembering to replicate it.

## Restoring

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops --decrypt archive/xdeca-appdirs-20260902.yaml \
  | python3 -c "import sys,yaml,base64; sys.stdout.buffer.write(base64.b64decode(yaml.safe_load(sys.stdin)['archive_b64']))" \
  > xdeca-appdirs.tar.gz

shasum -a 256 xdeca-appdirs.tar.gz   # must equal the sha256 above
tar xzf xdeca-appdirs.tar.gz
```

Verify the hash before trusting the output. A decrypt that silently produced the
wrong bytes and a decrypt that worked look identical until you check.

## Adding something here

Only if all three hold: it must outlive the machine it is on, it contains
secrets so it cannot be committed plainly, and it is small enough that base64 in
git is not absurd (single-digit MB at most). Anything larger belongs in the
release-asset tier — see `reference_release_asset_backup_storage_tier.md`.
