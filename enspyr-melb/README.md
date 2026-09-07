# enspyr-melb

Tenant config for the **enspyr-melb** box (`158.179.17.233`, ap-melbourne-1).
Config-only: holds SOPS secrets, no source.

Currently carries the OCI Object Storage credentials that the Outline and Kan.bn
stacks will share. Those stacks are not deployed yet — see `claude-tasks#3849`.

## Why object storage instead of MinIO

The Melbourne tenancy's **20 GB Object Storage** Always Free grant is a *separate*
pot from the 200 GB block-volume grant, and it was sitting at zero. Using it means
no MinIO container, no `storage.enspyr.co` vhost, no extra credentials — and the
files live **off the box**, so losing the boot volume does not lose them. That last
point is the actual argument; the free capacity is a bonus.

## The endpoint hostname is not the obvious one

```
✅ https://axh4zoguokfj.compat.objectstorage.ap-melbourne-1.oci.customer-oci.com
❌ https://axh4zoguokfj.compat.objectstorage.ap-melbourne-1.oraclecloud.com
```

**The wrong one resolves, serves TLS, returns HTTP 200 on a bare GET, and answers
with well-formed S3 XML errors.** Its error for a correctly-signed request is
`SignatureDoesNotMatch: The secret key required to complete authentication could
not be found. The region must be specified if this is not the home region.` —
which reads as a credential or region problem and is neither. Cost ~40 minutes of
chasing propagation delays and home-region settings on 2026-09-07.

## Path-style addressing is required

Virtual-hosted style (`https://vhcompat.objectstorage.<region>.oci.customer-oci.com`)
returns `NoSuchBucket` for buckets that demonstrably exist. Both apps must set
their force-path-style flag — `AWS_S3_FORCE_PATH_STYLE=true` for Outline,
`S3_FORCE_PATH_STYLE=true` for Kan.bn.

## A local `~/.aws/config` can break signing

If `~/.aws/config` sets a different default `region` (this Mac had
`ap-southeast-2`), it leaks into some aws-cli operations even when
`AWS_DEFAULT_REGION` is exported, and requests get signed for the wrong region —
producing the *same* `SignatureDoesNotMatch` message. When testing by hand:

```bash
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_DEFAULT_REGION=ap-melbourne-1
```

## The credential is unrecoverable if lost

OCI Customer Secret Keys show the secret **once, at creation**. `oci iam
customer-secret-key list` returns `display-name`, `id`, `lifecycle-state` — and no
`key` field. If `enspyr-melb/secrets.yaml` is ever lost, the credential cannot be
read back; it must be deleted and a new one minted, and every consumer updated.

Key in use: `enspyr-melb-s3-outline-kanbn` (ACTIVE), created 2026-09-07.

## Verified working 2026-09-07

LIST · PUT · GET · DELETE · **multipart >5 MB** (12 MB round-trip, sha256
identical) · **presigned URLs fetched anonymously** — the last matters most,
because it is how Outline serves every image to a browser. Unsigned access is
refused.

Buckets: `enspyr-outline`, `enspyr-kanbn-avatars`, `enspyr-kanbn-attachments`
(all `NoPublicAccess`).
