# Free Cloud Servers with OCI Always Free Tier

This guide walks you through setting up an automated script that keeps trying to grab a free ARM server from Oracle Cloud until it works. These are legitimately capable machines (2 CPU cores, 12GB RAM) and they're **free** on Oracle's Always Free tier.

> ⚠️ **Oracle halved the Ampere allowance on 15 June 2026**, from 4 OCPU / 24 GB to **2 OCPU / 12 GB**, with no announcement — just a docs edit. This guide reflects the post-halving numbers. Two consequences worth knowing before you start:

The catch? Everyone wants one, so they're almost always "out of capacity." Hence the retry script — it tries every 5 minutes until one slips through.

## What You're Getting

```
┌─────────────────────────────────────────┐
│  Oracle Cloud Always Free ARM Instance  │
│                                         │
│  • 2 OCPU (ARM cores) / 12GB RAM        │
│  • Up to 200GB disk                     │
│  • Ubuntu 24.04                         │
│  • Public IP address                    │
│  • Actually free. Forever. Not a trial. │
└─────────────────────────────────────────┘
```

But the ARM instance is just the headliner. The Always Free tier comes with a lot more that most people never discover.

### The Full Always Free Inventory

**Compute** — 2.25 CPUs and 14 GB RAM total, across two separate CPU budgets:

| Shape | CPUs | RAM | Max Instances | Notes |
|-------|------|-----|---------------|-------|
| VM.Standard.A1.Flex (Arm) | 2 OCPUs | 12 GB | 2 | Ampere Altra 3 GHz. Split OCPUs and RAM however you want across instances. **Halved from 4/24 on 15 Jun 2026** |
| VM.Standard.E2.1.Micro (AMD x86) | 1/8 OCPU each | 1 GB each | 2 | **Independent CPU budget** — doesn't touch the Arm allocation. Burstable above baseline |

The Arm allowance is metered as **1,500 OCPU-hours + 9,000 GB-hours per month**, which is what 2 OCPU / 12 GB running 24×7 works out to. Because it's hours rather than instances, splitting into 2 × 1 OCPU / 6 GB later costs a rebuild, not quota.

The Micro instances are the sleeper pick. They run on completely different x86 hardware, so you're getting extra compute on top of the 2 Arm cores. Each gets its own public IP and 50 Mbps internet bandwidth. Good for monitoring, cron runners, small proxies, or a Tailscale exit node. They also tend to *have* capacity when Arm doesn't — useful if you want an always-on host to run the retry loop itself.

**Storage:**

| Resource | Limit |
|----------|-------|
| Boot + block volumes | 200 GB total (home region only) |
| Volume backups | 5 |
| Object Storage | 20 GB + 50K API calls/month (S3-compatible) |

The boot volume defaults to 50 GB but you can resize it online up to 200 GB at any time. No reboot needed — just `growpart` + `resize2fs` after the OCI resize completes.

**Managed Databases** (if you don't want to self-host):

| Service | Limit |
|---------|-------|
| Autonomous Database (Oracle) | 2 instances — 1 OCPU + 20 GB each |
| MySQL HeatWave | 1 node — 50 GB data + 50 GB backup |
| NoSQL Database | 3 tables × 25 GB, 133M reads+writes/month |

**Networking:**

| Resource | Limit |
|----------|-------|
| VCNs | 2 |
| Flexible Load Balancer (L7) | 1 — 10 Mbps, 16 listeners, 1024 backends |
| Network Load Balancer (L4) | 1 — 50 listeners, 1024 backends |
| Site-to-Site VPN | 50 IPSec connections |
| Outbound data transfer | 10 TB/month |
| VCN Flow Logs | 10 GB/month |
| Bastion (managed SSH jump host) | Free, no stated limit |

10 TB/month outbound is insane — AWS charges ~$0.09/GB for egress, so that's ~$900/month worth of data transfer, free.

**Observability & Messaging:**

| Resource | Limit |
|----------|-------|
| Email Delivery | 3,000 emails/month |
| Monitoring | 500M ingestion + 1B retrieval data points |
| Notifications | 1M HTTPS + 1K email per month |
| APM | 1,000 tracing events/month + 10 synthetic runs/hour |

**Security:**

| Resource | Limit |
|----------|-------|
| Vault (KMS) | Unlimited software keys, 20 HSM keys, 150 secrets |
| Certificates | 5 CAs + 150 certs |

> **The one rule:** all resources must be in your **home region** to stay free. Pick your region carefully at signup — you can't change it later.

---

## What You'll Need

- A machine that stays on 24/7 (a Raspberry Pi is perfect, but any always-on Linux box works)
- An Oracle Cloud account (free)
- ~30 minutes of setup time
- The retry script from this repo: [`scripts/oci-retry-provision.sh`](../scripts/oci-retry-provision.sh)

---

## Step 1: Create an Oracle Cloud Account

Go to [cloud.oracle.com](https://cloud.oracle.com) and sign up for a free account.

Pick a **Home Region** close to you — this matters because Always Free resources are region-locked. You can't change it later.

> **Pro tip:** Less popular regions (like Melbourne or Sydney) tend to have more capacity than US regions. Pick somewhere not everyone else is picking.

Once you're in, consider upgrading to **Pay As You Go (PAYG)**. This does NOT mean you'll be charged — Always Free resources stay free. But PAYG accounts get priority for capacity, which dramatically improves your chances. Our Sydney instance provisioned within minutes of upgrading to PAYG.

To upgrade:

1. Log in to [cloud.oracle.com](https://cloud.oracle.com)
2. Open the **hamburger menu** (top-left) → **Billing & Cost Management** → **Upgrade and Manage Payment**
3. Click **Upgrade to Pay As You Go**
4. Add a credit/debit card (required for verification — you won't be charged for Always Free resources)
5. Accept the terms and confirm

The upgrade takes effect immediately.

---

## Step 2: Install the OCI CLI

On your always-on machine (the Pi, or wherever the retry script will run):

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

Follow the prompts. Accept the defaults.

Then verify it works:
```bash
oci --version
```

> **Official install docs:** [Installing the CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) — covers the quickstart installer above plus alternatives (MacOS Homebrew: `brew install oci-cli`, Windows) and prerequisites.

---

## Step 3: Set Up OCI Authentication

Oracle has a setup wizard that handles all the API key configuration:

```bash
oci setup config
```

This will ask you a series of questions. Here's where to find the answers:

| Question | Where to find it |
|----------|-----------------|
| **User OCID** | OCI Console → Profile (top right) → My Profile → OCID (copy it) |
| **Tenancy OCID** | OCI Console → Profile → Tenancy → OCID |
| **Region** | The home region you picked at signup (e.g., `ap-sydney-1`) |
| **Generate API key?** | Say **yes** — it creates the key for you |

When it generates the key, it'll print a **public key** block. You need to upload it:

1. Go to OCI Console → Profile → My Profile → API Keys → Add API Key
2. Choose "Paste Public Key"
3. Paste the public key the CLI just printed
4. Click Add

That's it. The CLI handles the private key, the config file, all of it.

> **Multiple accounts?** If you want to try multiple OCI regions/accounts (improves your odds), run `oci setup config` again and give each one a different **profile name**. The config file lives at `~/.oci/config` and looks like:
> ```ini
> [DEFAULT]
> user=ocid1.user.oc1..aaaa...
> fingerprint=ab:cd:ef:...
> tenancy=ocid1.tenancy.oc1..aaaa...
> region=ap-melbourne-1
> key_file=~/.oci/oci_api_key.pem
>
> [sydney]
> user=ocid1.user.oc1..bbbb...
> fingerprint=12:34:56:...
> tenancy=ocid1.tenancy.oc1..bbbb...
> region=ap-sydney-1
> key_file=~/.oci/sydney_api_key.pem
> ```

---

## Step 4: Gather Your OCI Resource IDs

You need a few IDs from the OCI Console. It's just clicking and copying:

### 4a. Compartment ID

Your tenancy OCID doubles as the root compartment ID. You already have this from Step 3.

### 4b. Create a VCN (Virtual Network)

OCI Console → Networking → Virtual Cloud Networks → **Start VCN Wizard** → "Create VCN with Internet Connectivity"

- Name it whatever you want (e.g., `my-vcn`)
- Accept defaults
- Click Create

Once created, go into the VCN → Subnets → click the **Public Subnet** → copy the **Subnet OCID**.

> ⚠️ **Use the wizard, not the plain "Create VCN" button next to it.** *Create VCN* builds a **private-only** network — no internet gateway, empty route table. Everything downstream still appears to work: the script provisions successfully, the instance reaches RUNNING, and OCI assigns it a real public IP. But nothing can reach it and it can't reach anything, and the console gives you no hint that the network is the problem.
>
> A public IP is **not** the same as internet reachability. Three layers must all line up — internet gateway → route rule → security list — and plain *Create VCN* gives you only the third.

**Verify before moving on.** This costs 30 seconds and is the cheap version of a multi-hour debug. On the VCN's detail page:

- **Internet Gateways** → lists one, state *Available*. **Empty means you used the wrong button.**
- **Route Tables** → the table on your public subnet has a rule `0.0.0.0/0 → <your internet gateway>`. An empty rules list is the same fault.
- **Security Lists** → ingress includes TCP 22.

If a gateway is missing you do **not** need to rebuild — see ["SSH connection times out"](#ssh-connection-times-out) in Troubleshooting for the two commands that repair it in place on a running instance.

### 4c. Find an ARM Image ID

OCI Console → Compute → Instances → Create Instance (don't actually create it yet!)

- Change the **Shape** to `VM.Standard.A1.Flex` (that's the free ARM one)
- Under **Image**, pick **Ubuntu 24.04** (Canonical)
- Click "Change Image" to see the image details — copy the **Image OCID**
- Cancel out of the create dialog

### 4d. Availability Domain

In that same Create Instance dialog, the **Availability Domain** is shown at the top. It looks like `Xxxx:REGION-AD-1`. Copy it exactly.

---

## Step 5: Set Up an SSH Key

The instance needs an SSH key so you can log in after it's created.

If you don't already have one:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

This creates a key pair. The script will pass the public key to Oracle when creating the instance, and then you can SSH in with the private key.

---

## Step 6: Install Dependencies

On your local machine:

```bash
# jq for parsing JSON responses from OCI
sudo apt-get install -y jq bc

# yq for parsing the accounts config file
pip3 install yq
```

---

## Step 7: Create the Accounts Config

Create a directory for the provisioning scripts and copy the retry script:

```bash
mkdir -p ~/oci-provision

# Copy the script from this repo (or download it)
cp scripts/oci-retry-provision.sh ~/oci-provision/retry-provision.sh
chmod +x ~/oci-provision/retry-provision.sh
```

Keep `retry-provision` in the filename — the auto-disable step runs `crontab -l | grep -v "retry-provision" | crontab -`, so renaming it silently breaks the "stop when finished" behaviour.

**Now edit your copy — three lines matter:**

| Line | Ships as | Change to | Why |
|---|---|---|---|
| `FULL_OCPUS` / `FULL_MEM` (~L19-20) | `4` / `24` | **`2`** / **`12`** | Post-15-Jun-2026 Arm allowance. Leave it at 4/24 on a new tenancy and the resize can never succeed, so the script never reaches "full", never self-disables, and retries a doomed API call every 5 minutes forever. |
| `SSH_KEY_PATH` (~L14) | `~/.ssh/id_ed25519.pub` | your actual **SSH public key** | Baked into the instance at launch and your *only* way in. A wrong path fails the launch; a stale key gives you a box you can't log into. Must be an SSH public key (`ssh-ed25519 AAAA…`), **not** an OCI API key. |
| `--boot-volume-size-in-gbs` (~L153) | `50` | **`100`** (up to 200) | 200 GB is your whole-tenancy volume budget and it's free. Growing later works online, but there's no reason to defer it. |

Leave `SMALL_OCPUS=1` / `SMALL_MEM=6` alone — that's the small-first strategy, and raising it is what gets you refused.

Create `~/oci-provision/accounts.yaml` with your details:

```yaml
# OCI accounts for auto-provisioning
# Paste in the IDs you collected in Step 4

accounts:
  - name: my-server           # whatever you want to call it
    profile: DEFAULT           # matches the profile name in ~/.oci/config
    region: ap-sydney-1        # your OCI region
    compartment_id: "ocid1.tenancy.oc1..paste-yours-here"
    subnet_id: "ocid1.subnet.oc1.ap-sydney-1.paste-yours-here"
    image_id: "ocid1.image.oc1.ap-sydney-1.paste-yours-here"
    availability_domain: "Xxxx:AP-SYDNEY-1-AD-1"
    instance_name: "my-server"
```

> **Want to double your chances?** Create a second free OCI account in a different region, run `oci setup config` with a new profile name, and add a second entry to this file. The script tries all accounts every cycle.

---

## Step 8: Set Up the Cron Job

This is the magic — cron runs the script every 5 minutes, 24/7, until an instance appears:

```bash
# Add the cron job
(crontab -l 2>/dev/null; echo "*/5 * * * * $HOME/oci-provision/retry-provision.sh") | crontab -

# Verify it's installed
crontab -l
```

---

## Step 9: Wait (and Watch)

The script logs everything to `~/oci-provision.log`. Check on it:

```bash
# See recent activity
tail -20 ~/oci-provision.log

# Watch it live
tail -f ~/oci-provision.log
```

You'll see a lot of "Out of capacity" messages. That's normal. It could take hours, days, or (rarely) weeks. PAYG accounts tend to succeed much faster.

When it finally works, you'll see:
```
🎉 Small instance created!
```

Then a few cycles later:
```
🎉 Resize initiated! Instance will reboot with 2 OCPUs.
```

And finally:
```
✅ Full instance running (2 OCPUs) at 123.45.67.89 — nothing to do!
All instances at full capacity! Disabling cron job. 🎊
```

---

## Step 10: Log In to Your New Server

Once the instance is running:

```bash
# SSH in (ubuntu is the default user for Ubuntu images on OCI)
ssh ubuntu@<your-instance-ip>
```

Your 2-core ARM server with 12GB of RAM is ready to go.

**Verify cloud-init actually did its job — don't assume it:**

```bash
docker --version              # should print a version
cat /etc/cron.d/keep-alive    # should show the 6-hourly job
```

> ⚠️ **Cloud-init runs once, at first boot, and marks itself `done` whether or not the commands inside it succeeded.** If the network was broken at that moment (see the Step 4b warning), the `apt-get install docker.io docker-compose` half died with `Network is unreachable` while the parts needing no network — the keep-alive heredoc — completed perfectly. You get a box that looks provisioned and has **no Docker**. Fixing the network afterwards does not retroactively install anything, and cloud-init will never retry.
>
> ```bash
> cloud-init status                                    # "done" even on failure — not a health check
> grep -iE "Network is unreachable|Failed to fetch" /var/log/cloud-init-output.log
> sudo apt-get update && sudo apt-get install -y htop curl docker.io docker-compose
> ```
>
> Note cloud-init installs the distro's `docker.io` + **compose v1**. If you want upstream Docker CE with the `docker compose` v2 plugin, install it *before* anything is running: `curl -fsSL https://get.docker.com | sudo sh`.

---

## Step 11: Reserve a Static IP (do this before anything points at the box)

The public IP the script assigned at launch is **ephemeral** — it's released and replaced whenever the instance stops and starts (a maintenance reboot, a resize, an accidental stop). Anything pinned to it — DNS records, SSH config, firewall allow-lists on other hosts — silently breaks the next time that happens. Converting to a **reserved** IP fixes the address for the life of the tenancy. It's free, and it's the one piece that's genuinely painful to retrofit once things depend on the address.

**Check what you have first.** `lifetime` tells you:

```bash
# The ephemeral IP lives at AD scope; a reserved one lives at REGION scope
oci network public-ip list --scope AVAILABILITY_DOMAIN \
  --availability-domain "<Xxxx:REGION-AD-1>" \
  --compartment-id "<your-tenancy-ocid>" \
  | jq -r '.data[] | "\(.["ip-address"])  lifetime=\(.lifetime)"'
  
# lifetime=EPHEMERAL  → not permanent yet, do the rest of this step
# lifetime=RESERVED   → already done
```

> ⚠️ **Reserved IPs come from Oracle's pool — you get a *new* address, not a promotion of the current one.** There is no ephemeral→reserved conversion: the API can only *delete* an ephemeral IP, and reserved addresses are allocated from Oracle's block. So this step changes the box's public IP exactly once. Update DNS / SSH config / allow-lists to the new address afterwards — then it never changes again. Plan a couple of minutes where the box has no public IP mid-swap; existing SSH sessions survive it, new ones need the new address.

### The console path (simplest)

1. Instance → **Attached VNICs** → click the VNIC → **IPv4 Addresses**.
2. On the row with the public IP, the **⋮** menu → **Edit**.
3. Set **Public IP type** to **Reserved**, choose **Create a new reserved public IP** (or pick an existing unassigned one), and save. The ephemeral is released and the reserved one takes its place — note the new address.

### The CLI path

Assigning a reserved IP requires the target private IP to have **no** public IP, so the ephemeral must go first. Order matters — do it in one sitting:

```bash
COMP="<your-tenancy-ocid>"
INSTANCE_ID="<your-instance-ocid>"          # from the launch log, or: oci compute instance list --compartment-id "$COMP"

# Resolve the primary private IP by walking instance → VNIC → private IP.
# You never type these OCIDs by hand — each is found from the one before it.
VNIC_ID=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" \
  | jq -r '.data[] | select(.["is-primary"]) | .id')
PRIVATE_IP_ID=$(oci network private-ip list --vnic-id "$VNIC_ID" \
  | jq -r '.data[] | select(.["is-primary"]) | .id')

# 1. Create a reserved IP in your pool (unassigned — no --private-ip-id yet).
#    Do NOT pass --scope: it's a create-time error. RESERVED is always regional;
#    scope is derived from --lifetime. --wait-for-state makes it synchronous so
#    $RESERVED_ID is populated before step 3 uses it.
RESERVED_ID=$(oci network public-ip create --lifetime RESERVED \
  --compartment-id "$COMP" --display-name my-static-ip \
  --wait-for-state AVAILABLE | jq -r '.data.id')

# 2. Delete the ephemeral (unassigns + frees it — the box briefly has no public IP).
#    Find its OCID by matching the ephemeral assigned to your private IP.
#    --all silences a pagination warning and ensures your IP isn't on page 2.
EPHEMERAL_ID=$(oci network public-ip list --scope AVAILABILITY_DOMAIN --all \
  --availability-domain "<Xxxx:REGION-AD-1>" --compartment-id "$COMP" \
  | jq -r --arg p "$PRIVATE_IP_ID" '.data[] | select(.["assigned-entity-id"]==$p) | .id')
oci network public-ip delete --public-ip-id "$EPHEMERAL_ID" --force --wait-for-state TERMINATED

# 3. Assign the reserved IP to the primary private IP. Asynchronous — wait for it,
#    or a read-back in step 4 can race and still show the old state.
oci network public-ip update --public-ip-id "$RESERVED_ID" --private-ip-id "$PRIVATE_IP_ID" \
  --wait-for-state ASSIGNED

# 4. Read back the new permanent address
oci network public-ip get --public-ip-id "$RESERVED_ID" | jq -r '.data | "\(.["ip-address"])  lifetime=\(.lifetime)  state=\(.["lifecycle-state"])"'
```

**Verify** on the new address — pass your key explicitly if you don't have an SSH-config alias yet, since the raw `ubuntu@ip` form won't pick up `oci_key` on its own:

```bash
ssh -i ~/.ssh/oci_key ubuntu@<new-reserved-ip> 'hostname && echo reachable'
```

Then **update everything that referenced the old address** — DNS A-records, `~/.ssh/config` `HostName` lines, and any remote firewall allow-lists. One more gotcha: the new IP is a new entry in `~/.ssh/known_hosts`, so the first connection re-prompts to accept the host key even though it's the same box. That's expected, not a MITM warning — unless you *also* see a "REMOTE HOST IDENTIFICATION HAS CHANGED" block, which would mean the new IP was recycled from another host you'd previously connected to (clear it with `ssh-keygen -R <new-ip>`).

---

## How It Works

### Small-First Strategy

Oracle has limited ARM capacity. Requesting the full 2 OCPU/12GB often fails. But requesting 1 OCPU/6GB succeeds much more often. Once you have a small instance, resizing it is easier because you already have a placement — Oracle just needs to allocate more resources on the same host.

Don't "optimise" `SMALL_OCPUS` up to 2 to skip a step — asking for the full allocation up front is precisely the request that gets refused, and you lose the placement advantage.

### Random Jitter

The script sleeps 0-90 seconds randomly before each attempt. This avoids a perfectly predictable 5-minute request pattern that might look automated (because it is, but let's be polite about it).

### Keep-Alive Cron

Oracle can reclaim idle Always Free instances. The cloud-init script installs a keep-alive job that runs every 6 hours, doing just enough CPU work to not look idle. If you've upgraded to PAYG, this is technically unnecessary — but it doesn't hurt.

### Lock File

The lock file prevents two copies of the script from running at once (which could happen if a cycle takes longer than 5 minutes due to jitter + API latency).

### Auto-Disable

Once all configured instances are at full size, the script removes itself from cron. No need to manually clean up.

---

## Optional: Notifications

Want to get pinged when it succeeds? Add [ntfy.sh](https://ntfy.sh) support — a dead simple push notification service. No account needed.

Add these to your copy of the script (before the `log()` function):

```bash
NTFY_TOPIC="my-oci-alerts"  # pick any unique topic name

notify() {
    curl -s -H "Title: $1" -H "Priority: ${3:-default}" \
        -d "$2" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true
}
```

Then install the ntfy app on your phone and subscribe to your topic. No account, no API key, no auth — you just pick a topic name and subscribe.

Sprinkle `notify` calls after the success messages:
```bash
notify "Instance Created!" "Small instance provisioned — resize coming next cycle"
notify "Resize Complete!" "Full 2 OCPU / 12GB instance is running at $IP" "high"
```

---

## Troubleshooting

### Can't reach the instance — start with *which* error

The exact failure text names the layer. Check it before changing anything, because these have nothing to do with each other:

| Symptom | Means | Look at |
|---|---|---|
| `Operation timed out` | Packets vanished silently. Nothing rejected them — there was **no path**. | Cloud network: gateway, route table, security list. **Not the box.** |
| `Connection refused` | Packets **arrived** and something said no. Network is fine. | The box: sshd down, or host iptables `REJECT`. |
| `Could not resolve hostname` | Never left your machine. | Your `~/.ssh/config`. |
| `Permission denied (publickey)` | Network *and* sshd are both fine. | Wrong key, or wrong user — it's `ubuntu`, not `root`. |

Timeout vs. refused is the whole diagnosis. **A timeout means stop looking at the instance** — you can't fix a missing route by rebooting a VM, and the console will happily show RUNNING, green, with a valid public IP the entire time.

### SSH connection times out

Almost always the Step 4b fault: a VCN built without an internet gateway. Check the three layers, outermost first:

```bash
COMP=ocid1.tenancy.oc1..…
VCN=ocid1.vcn.oc1.<region>.…
SUBNET=ocid1.subnet.oc1.<region>.…

# 1. Does an internet gateway exist at all?  (empty output = the fault)
oci network internet-gateway list --compartment-id "$COMP" --vcn-id "$VCN" \
  | jq -r '.data[] | "\(.["display-name"]) enabled=\(.["is-enabled"])"'

# 2. Does the subnet's route table point at it?  (empty rules = the fault)
RT=$(oci network subnet get --subnet-id "$SUBNET" | jq -r '.data["route-table-id"]')
oci network route-table get --rt-id "$RT" \
  | jq -r '.data["route-rules"][] | "\(.destination) -> \(.["network-entity-id"])"'

# 3. Is port 22 open?
SL=$(oci network subnet get --subnet-id "$SUBNET" | jq -r '.data["security-list-ids"][0]')
oci network security-list get --security-list-id "$SL" \
  | jq -r '.data["ingress-security-rules"][] | "proto=\(.protocol) src=\(.source) ports=\(.["tcp-options"]["destination-port-range"] // "all")"'
```

**Fix, if 1 or 2 came back empty.** No rebuild needed — this repairs in place on a running instance and takes effect in seconds:

```bash
IGW=$(oci network internet-gateway create \
  --compartment-id "$COMP" --vcn-id "$VCN" \
  --is-enabled true --display-name my-igw | jq -r '.data.id')

oci network route-table update --rt-id "$RT" --force \
  --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW\"}]"
```

SSH succeeding only proves **inbound** works. Confirm outbound too, then go re-check cloud-init (Step 10) — if the gateway was missing at first boot, the package install already failed silently:

```bash
ssh ubuntu@<ip> 'curl -s -o /dev/null -w "%{http_code}\n" http://ports.ubuntu.com/ubuntu-ports/'   # want 200
```

### `Connection refused` on ports 80/443 (but 22 works)

OCI's Ubuntu images ship **host-level iptables rules** blocking everything except 22, *in addition to* the cloud security list. Both layers must be open:

```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save        # survives reboot
```

Don't `ufw enable` on top of these without replicating the port 22 rule first — it will lock you out. Useful tell: a port missing from **iptables** gives `Connection refused`, while a port missing from the **security list** gives a timeout — so the error tells you which layer to fix.

### Launch fails with a config error (not capacity)

`Out of capacity` is normal and self-resolving. Anything else in `~/oci-provision.log` is a config bug that will never fix itself, so read the log rather than assuming you're just waiting. Two that cost real time:

| Log line | Cause |
|---|---|
| `Invalid ssh public key type "-----BEGIN"` | `SSH_KEY_PATH` points at an **OCI API key** (`-----BEGIN RSA PUBLIC KEY-----`) instead of an SSH public key (`ssh-rsa AAAA…` / `ssh-ed25519 AAAA…`). Two different systems: the API key authenticates the CLI to Oracle, the SSH key logs you into the box. |
| `key_file's value '…' must be a valid file path` | A path in `~/.oci/config` missing its leading `/`. The CLI does not expand it and every call fails. |

### "Out of capacity" forever
- Upgrade to PAYG (seriously, this is the biggest factor)
- Try a different region (create another account)
- Be patient — some people wait a week, some get lucky in an hour

### "Authorization failed"
Run `oci setup config` again. The wizard handles everything. Make sure you uploaded the public key to the OCI Console (Step 3).

### "Could not find subnet/image"
Double-check the OCIDs in your `accounts.yaml`. They're long and easy to copy wrong. Make sure the image ID is for your specific region — image IDs are different per region.

### Script isn't running
```bash
# Check if cron is running
systemctl status cron

# Check if the job is registered
crontab -l | grep provision
```

### Rate limited (429)
The script handles this automatically — it backs off for 60 seconds. If it happens a lot, consider increasing the cron interval from 5 to 10 minutes.

---

## Security Notes

- The OCI CLI config (`~/.oci/config`) contains your API key path. Keep it safe.
- Your SSH private key (`~/.ssh/id_ed25519`) is your login credential for the instance. Don't share it.
- The instance's Security List (firewall) is restrictive by default. Only port 22 (SSH) is open. You'll need to add rules for any other ports you want to expose (80, 443, etc.) via OCI Console → Networking → VCN → Security Lists.

---

## Quick Reference

```bash
# Check provisioning status
tail -20 ~/oci-provision.log

# Manually trigger a provisioning attempt
~/oci-provision/retry-provision.sh

# Check cron is active
crontab -l | grep provision

# Remove the cron job (give up / already done)
crontab -l | grep -v "retry-provision" | crontab -

# SSH into your instance once it's running
ssh ubuntu@<ip-address>
```
