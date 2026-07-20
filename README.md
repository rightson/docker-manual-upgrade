# GitLab Offline Upgrade Utility (16.1 → latest)

Back up, upgrade **through every required stop**, verify, and (if needed) roll
back production GitLab **16.1** servers that live in an **air‑gapped** network.

## Why this exists

This utility is built for running GitLab inside an **air‑gapped development
environment for highly confidential product development** — the kind of network
that, by policy, has **no outbound internet access** so that source code and
build artefacts for a strictly confidential product never leave the perimeter.
In that setting you cannot `apt`/`yum`/`docker pull` on the servers, and a
botched upgrade can't be rescued by pulling a fixed package over the network. So
the tool makes the whole lifecycle **deterministic and reversible offline**:
every package/image is fetched once on a connected staging machine, transferred
in, verified by checksum, applied through GitLab's mandatory upgrade stops, and
— if anything goes wrong — rolled back from a backup taken moments earlier. No
step ever reaches out to the internet from inside the enclave.

## Supported servers

| Install method | Operating systems | Handled by |
|----------------|-------------------|------------|
| **Omnibus `.deb`** package | Ubuntu 22.04 (jammy), 24.04 (noble), 20.04 (focal¹) | `--type deb` |
| **Omnibus `.rpm`** package | RHEL / EL **8** and 9 (Rocky, Alma, CentOS Stream) | `--type rpm` |
| **Docker** image (`gitlab/gitlab-ce`) | any Linux host | `--type docker` |

¹ focal has no 19.x packages — see the OS notes below.

Because the servers have no internet, you **download everything on an online
Windows machine**, copy one self‑contained *bundle* folder to each server, and
run the **same Linux script** there to back up → upgrade → (optionally) roll
back. No package or image is ever fetched on the servers themselves.

> ⚠️ **Production safety.** GitLab upgrades run irreversible database
> migrations. Always (1) test this on a clone/staging copy first, (2) let the
> tool take its automatic backup, and (3) keep the backup folder — including
> `gitlab-secrets.json` — somewhere off the server. Rolling back **restores a
> backup**; it cannot "undo" migrations in place.

---

## How it works

```
   ┌─────────────── ONLINE (Windows) ───────────────┐        ┌──────── OFFLINE (Ubuntu servers) ────────┐
   │  Download-GitLabAssets.ps1                      │        │  gitlab-offline-upgrade.sh                │
   │   • reads config/upgrade-path.conf              │  copy  │   preflight → backup → upgrade → verify   │
   │   • downloads .deb / .rpm packages              │ ─────► │   (steps through each required stop,      │
   │   • docker pull + save   (docker server)        │ bundle │    waiting for DB + background migrations │
   │   • copies the Linux scripts + checksums        │        │    between each one)                      │
   │   → produces  gitlab-offline-bundle/            │        │   rollback  (restore from backup)         │
   └─────────────────────────────────────────────────┘        └───────────────────────────────────────────┘
```

### The required upgrade path

You cannot jump straight from 16.1 to the latest release — GitLab mandates
intermediate "stops". The default path (validated against
`packages.gitlab.com`, July 2026) is defined in
[`config/upgrade-path.conf`](config/upgrade-path.conf):

```
16.3.9 → 16.7.10 → 16.11.10 →
17.1.8 → 17.3.7 → 17.5.5 → 17.8.7 → 17.11.7 →
18.2.8 → 18.5.7 → 18.8.11 → 18.11.7 →
19.1.2 (latest)
```

The Linux script auto‑selects only the stops **above each server's detected
version**, so the one bundle works for both 16.1 servers even if their exact
patch level differs. Verify/adjust the path any time with the official
[GitLab upgrade‑path tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/).

---

## Repository layout

```
config/upgrade-path.conf          # the ordered list of required stops (editable)
windows/Download-GitLabAssets.ps1 # run on the ONLINE Windows box
linux/gitlab-offline-upgrade.sh   # the ONE command you run on each server
linux/lib/*.sh                    # helper libraries (sourced by the main script)
examples/                         # reference notes
```

---

## Step 1 — Download on Windows (online)

Requirements:
- Windows PowerShell 5.1+ (or PowerShell 7).
- **Docker Desktop** running — only needed if you download Docker images
  (`-Docker`). Not needed for `.deb` only.
- Enough free disk: the full path is **~25–35 GB** for `.deb` and a similar
  amount again for saved Docker images.

First, find each server's **exact current version** (needed so rollback is
possible):
- deb server: `cat /opt/gitlab/embedded/service/gitlab-rails/VERSION`
- docker server: `docker exec <container> cat /opt/gitlab/embedded/service/gitlab-rails/VERSION`

**1a. Validate the path first** (HEAD‑checks every URL, downloads nothing):

```powershell
cd windows
.\Download-GitLabAssets.ps1 -CurrentVersion 16.1.8 -Validate
```

Fix any `MISSING` version in `config/upgrade-path.conf` and re‑validate until
all say `OK`.

**1b. Download the bundle** (both `.deb` for jammy and Docker images, plus the
16.1.8 rollback baseline):

```powershell
.\Download-GitLabAssets.ps1 -Codename jammy -CurrentVersion 16.1.8
```

Useful variants:

```powershell
# Only the deb server's packages (Ubuntu 22.04 / jammy):
.\Download-GitLabAssets.ps1 -Deb -Codename jammy -CurrentVersion 16.1.8

# Ubuntu 24.04 (noble) — noble packages exist from 17.1 onward:
.\Download-GitLabAssets.ps1 -Deb -Codename noble -CurrentVersion 17.3.7

# RHEL / EL 8 server (.rpm):
.\Download-GitLabAssets.ps1 -Rpm -ElVersion 8 -CurrentVersion 16.1.8

# Only the docker server's images:
.\Download-GitLabAssets.ps1 -Docker -CurrentVersion 16.1.6

# Enterprise Edition instead of Community Edition:
.\Download-GitLabAssets.ps1 -Edition ee -CurrentVersion 16.1.8
```

This produces `gitlab-offline-bundle/` containing `assets/`, the Linux scripts,
`bundle.conf`, and `SHA256SUMS`.

> **OS availability (validated 2026‑07):**
> - **Ubuntu 22.04 (jammy)** — all stops available.
> - **Ubuntu 24.04 (noble)** — packages start at **17.1.x** (24.04 postdates
>   16.x). A noble server is therefore already on ≥ 17.1; `-Validate` flags gaps.
> - **Ubuntu 20.04 (focal)** — `.deb` only up to **18.8.x**; there are **no 19.x
>   focal packages**, so a focal server needs an OS upgrade to jammy to go past
>   18.8.
> - **RHEL / EL 8** — all stops available as `.rpm`.
> - **Docker** — host OS is irrelevant (image is self‑contained).

---

## Step 2 — Transfer

Copy the **entire `gitlab-offline-bundle/` folder** to each server (USB, an
approved file drop, `scp` within the offline LAN, etc.). The same bundle can go
to **both** servers.

---

## Step 3 — On each server (offline)

```bash
cd gitlab-offline-bundle
chmod +x gitlab-offline-upgrade.sh

# See what will happen (detects deb / rpm / docker automatically):
sudo ./gitlab-offline-upgrade.sh status

# Verify checksums, disk, and that every needed asset is present:
sudo ./gitlab-offline-upgrade.sh preflight
```

`status` prints the detected install type, current version, the exact stops it
will apply, and whether each asset (and the rollback baseline) is present.

### Upgrade

```bash
# Full run: takes a backup, then steps through every required stop.
sudo ./gitlab-offline-upgrade.sh upgrade

# Unattended (no prompts):
sudo ./gitlab-offline-upgrade.sh upgrade --yes

# Cautious: apply ONE stop then stop, so you can validate between steps:
sudo ./gitlab-offline-upgrade.sh upgrade --step

# Go only as far as a specific version:
sudo ./gitlab-offline-upgrade.sh upgrade --to 16.11.10
```

For each stop the tool: installs the package / swaps the image → runs
`gitlab-ctl reconfigure` (schema migrations) → waits for services to become
ready → **waits for batched background migrations to finish** → then moves to
the next stop. Skipping the background‑migration wait is the most common way
real upgrades corrupt data; this tool blocks on it automatically.

The **docker** path preserves your container exactly: it reads the running
container's volumes, ports, hostname, restart policy and `GITLAB_OMNIBUS_CONFIG`
via `docker inspect`, prints the `docker run` it will execute (saved to
`last-docker-run.txt`), and reuses the same volumes so **no data is lost**.
If the container is `docker compose`‑managed, it instead bumps the image tag in
your compose file (backed up first) and runs `docker compose up -d`.

### Backup only (no upgrade)

```bash
sudo ./gitlab-offline-upgrade.sh backup
```

Produces, under `/var/opt/gitlab-offline-upgrade/backups/<timestamp>/`:
- the application‑data tar via `gitlab-backup create` (DB, repos, uploads, …),
- `gitlab-secrets.json` + `gitlab.rb` (**required** to decrypt a restore),
- a full `etc-gitlab.tar.gz`,
- `metadata.env` and (docker) `container-inspect.json`.

### Roll back

If an upgrade fails or you need to revert:

```bash
# Roll back to the most recent backup:
sudo ./gitlab-offline-upgrade.sh rollback

# Roll back to a specific backup directory:
sudo ./gitlab-offline-upgrade.sh rollback --backup /var/opt/gitlab-offline-upgrade/backups/20260719-101500
```

Rollback puts the **original version** back (from the bundle — this is why you
pass `-CurrentVersion` when downloading), restores the original secrets/config,
and restores the application‑data backup. That is the only GitLab‑supported way
to revert, so **a rollback is only as good as your pre‑upgrade backup.**

### Verify

```bash
sudo ./gitlab-offline-upgrade.sh verify   # prints version, runs gitlab:check
```

---

## Command / option reference

| Command | Purpose |
|--------|---------|
| `status` | Detect install, show version + planned path + asset presence. |
| `preflight` | Verify checksums, disk, and that all path assets exist. |
| `backup` | Full restorable backup (app data + secrets + config). |
| `upgrade` | Backup (unless `--skip-backup`) then step through the path. |
| `rollback` | Restore a backup (undo an upgrade). |
| `verify` | Post‑upgrade health checks. |

| Option | Meaning |
|--------|---------|
| `--type deb\|rpm\|docker\|auto` | Force install type (default: auto‑detect). |
| `--edition ce\|ee` | GitLab edition. |
| `--el-version N` | RHEL/EL major version for rpm (default: 8). |
| `--container NAME` | Docker container name (default: auto‑detect). |
| `--to VERSION` | Stop upgrading once VERSION is reached. |
| `--step` | Apply only the next single stop, then exit. |
| `--yes` | Don't prompt (unattended). |
| `--skip-backup` | Skip the automatic pre‑upgrade backup (not recommended). |
| `--bundle DIR` | Bundle root (default: script directory). |
| `--work-dir DIR` | State/logs/backups root (default `/var/opt/gitlab-offline-upgrade`). |
| `--backup DIR` | (rollback) which backup to restore. |

---

## Important assumptions & caveats

- **Test on staging first.** Clone the instance and rehearse the full path
  before touching production.
- **Downtime.** Each stop restarts GitLab and runs migrations; expect the
  instance to be unavailable during the run.
- **Disk.** Ensure ≥20 GB free on `/var/opt/gitlab` (deb/rpm) or `/var/lib/docker`
  (docker) for backups and migrations. `preflight` checks this.
- **Secrets are non‑negotiable.** Without `gitlab-secrets.json`, a restored
  backup cannot decrypt 2FA, CI/CD variables or tokens. Keep the backup folder
  off the server.
- **Custom backup paths.** The tool assumes the default
  `/var/opt/gitlab/backups`. If you set a custom `gitlab_rails['backup_path']`,
  adjust accordingly.
- **The path is data, not code.** Confirm it with the official upgrade‑path tool
  and always use the *latest patch* of each required minor.

See the header of each script (`--help`) for more detail.
