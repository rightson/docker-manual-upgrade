# GitLab Offline Backup / Restore / Upgrade Utility

Back up a whole GitLab instance into **one portable file**, restore that file onto
**another** GitLab server, and upgrade an **air‑gapped** GitLab **through every
required stop** — all from a handful of copy‑paste commands. Works for GitLab that
runs from the Omnibus **`.deb`** package (Debian/Ubuntu), the Omnibus **`.rpm`**
package (RHEL/EL 8+), or a **Docker** image.

> **New here? Read this first.** There are exactly **two machines** in this story:
> - an **online Windows PC** that can reach the internet (it *downloads* things), and
> - your **offline Linux GitLab server(s)** that cannot (they *run* things).
>
> You never run `apt`, `yum`, or `docker pull` on the offline server. Everything it
> needs is downloaded once on Windows and carried in.

---

## What you can do (quick map)

| I want to… | Where | Command |
|---|---|---|
| **Back up** all of GitLab into one file | offline server | `sudo ./gitlab-offline-upgrade.sh backup` |
| **Restore** that file onto another GitLab | the *other* server | `sudo ./gitlab-offline-upgrade.sh restore --from <file>` |
| **Download** all upgrade packages for my version | online Windows | `.\Download-GitLabAssets.ps1 -CurrentVersion 16.1.8` |
| Download **and SFTP‑push** them to the server, one command | online Windows | add `-SftpHost … -SftpUser … -SftpRemotePath …` |
| **Upgrade** GitLab to the latest version (offline) | offline server | `sudo ./gitlab-offline-upgrade.sh upgrade --path <bundle>` |
| **Undo** an upgrade that went wrong | offline server | `sudo ./gitlab-offline-upgrade.sh rollback` |

The upgrade command **takes a backup automatically before it touches anything**, so
requirement "back up before upgrading" is handled for you.

---

## Why this exists

This utility is built for running GitLab inside an **air‑gapped network** — the kind
that, by policy, has **no outbound internet access** so confidential source code never
leaves the perimeter. There you cannot `apt`/`yum`/`docker pull` on the servers, and a
botched upgrade can't be rescued by pulling a fixed package over the network. So the
tool makes the whole lifecycle **deterministic and reversible offline**: every
package/image is fetched once on a connected Windows machine, transferred in, verified
by checksum, and applied through GitLab's mandatory upgrade stops — with a full backup
taken first.

---

## Repository layout

```
config/upgrade-path.conf          # the ordered list of required upgrade stops (editable)
windows/Download-GitLabAssets.ps1 # run on the ONLINE Windows box (download + optional SFTP upload)
linux/gitlab-offline-upgrade.sh   # the ONE command you run on each server
linux/lib/*.sh                    # helper libraries (sourced by the main script)
examples/                         # reference notes (docker specifics)
```

The Windows downloader assembles a self‑contained **bundle** folder (packages +
scripts + a checksum file). You copy or SFTP that folder to each server and run the
Linux script from inside it.

---

# Part 1 — Backup & Restore

These two commands are independent of upgrading. Use them any time — to migrate GitLab
to new hardware, to keep an off‑site copy, or before risky maintenance.

## 1a. Backup → one portable file

On the GitLab server:

```bash
cd <bundle-folder>          # or any folder containing gitlab-offline-upgrade.sh + lib/
chmod +x gitlab-offline-upgrade.sh
sudo ./gitlab-offline-upgrade.sh backup
```

What it does:
1. Auto‑detects how GitLab runs here (deb / rpm / docker) and its version.
2. Runs `gitlab-backup create` (database, repositories, uploads, CI artifacts, …).
3. Also saves `gitlab-secrets.json` + `gitlab.rb` + the whole `/etc/gitlab`.
   > **Why secrets matter:** without `gitlab-secrets.json` the encrypted data (2FA,
   > CI/CD variables, tokens) in the backup **cannot be decrypted** after a restore.
4. Packs **all of the above into a single `.tar.gz`** you can carry anywhere:

```
[+] ONE portable backup file : /var/opt/gitlab-offline-upgrade/backups/gitlab-backup-gitlab01-16.1.8-20260721-101500.tar.gz
```

Choose where the file goes with `--out`:

```bash
sudo ./gitlab-offline-upgrade.sh backup --out /mnt/usb/gitlab-full-backup.tar.gz
```

> **Disk note:** the portable file contains the full application‑data tar, so you need
> free space roughly equal to your GitLab data size in the work directory (or wherever
> `--out` points).

## 1b. Restore that file onto **another** GitLab

GitLab can only restore a backup into an install running the **same version** and edition.
So on the destination machine:

1. **Install GitLab first** at the *same version* the backup came from (the version is in
   the backup's file name and printed by `restore`). Use this bundle's packages, e.g.
   `sudo dpkg -i assets/deb/jammy/gitlab-ce_16.1.8-ce.0_amd64.deb`, or your normal
   installer. For Docker, start a container on `gitlab/gitlab-ce:16.1.8-ce.0`.
2. Copy the portable backup file over, then:

```bash
sudo ./gitlab-offline-upgrade.sh restore --from /path/to/gitlab-full-backup.tar.gz
```

What it does:
1. Unpacks the file and reads its metadata (type / edition / version).
2. Detects the GitLab installed here and **warns loudly if the version doesn't match**.
3. Places the application‑data tar into GitLab's backup directory.
4. Restores `gitlab-secrets.json` + `gitlab.rb`, reconfigures.
5. Runs `gitlab-backup restore`, reconfigures, restarts, and runs health checks.

> This **overwrites** the destination's database, repositories and uploads with the
> backup's data. That's the point of a migration/restore — just be sure you're pointing
> at the right host.

**`restore` vs `rollback`:**
- **`restore`** imports a portable backup file into whatever GitLab is installed *now*
  (same or a different, freshly‑installed machine). This is the backup/migrate flow.
- **`rollback`** *undoes an in‑place upgrade* on the same host — it reinstalls the old
  version from the bundle and restores the pre‑upgrade backup. See Part 3.

---

# Part 2 — Download on Windows (online)

Everything the offline server needs is downloaded here first.

Requirements:
- Windows PowerShell 5.1+ (or PowerShell 7).
- **Docker Desktop** running — only if you download Docker images (`-Docker`).
- For SFTP upload: the built‑in **OpenSSH Client** (`sftp.exe`). Install via
  *Settings → Apps → Optional Features → OpenSSH Client* if `sftp` isn't found.
- Free disk: the full path is **~25–35 GB** for `.deb`, similar again for Docker images.

First, find each server's **exact current version** (needed so rollback/restore work):
- deb/rpm server: `cat /opt/gitlab/embedded/service/gitlab-rails/VERSION`
- docker server: `docker exec <container> cat /opt/gitlab/embedded/service/gitlab-rails/VERSION`

### Step 2a — Validate the path first (downloads nothing)

```powershell
cd windows
.\Download-GitLabAssets.ps1 -CurrentVersion 16.1.8 -Validate
```

This HEAD‑checks every download URL. Fix any `MISSING` version in
`config/upgrade-path.conf` and re‑validate until all say `OK`.

### Step 2b — Download the bundle

You give it **your current version** and it downloads every package on the path from
there to the latest, plus your version as a rollback baseline:

```powershell
# deb + docker (default), Ubuntu 22.04 (jammy):
.\Download-GitLabAssets.ps1 -Codename jammy -CurrentVersion 16.1.8

# Only .deb for the deb server:
.\Download-GitLabAssets.ps1 -Deb -Codename jammy -CurrentVersion 16.1.8

# RHEL / EL 8 server (.rpm):
.\Download-GitLabAssets.ps1 -Rpm -ElVersion 8 -CurrentVersion 16.1.8

# Only docker images:
.\Download-GitLabAssets.ps1 -Docker -CurrentVersion 16.1.6

# Enterprise Edition instead of Community Edition:
.\Download-GitLabAssets.ps1 -Edition ee -CurrentVersion 16.1.8
```

This produces `gitlab-offline-bundle/` containing `assets/`, the Linux scripts,
`bundle.conf`, and `SHA256SUMS`.

### Step 2c — Download **and** SFTP‑upload in the *same* command

Give it an SFTP target and it pushes the finished bundle straight to the server, into
the **remote path** you'll later hand to the Linux script:

```powershell
.\Download-GitLabAssets.ps1 -CurrentVersion 16.1.8 -Codename jammy `
    -SftpHost 10.0.0.5 -SftpPort 22 -SftpUser deploy -SftpRemotePath /srv/gitlab-bundle
```

- `-SftpHost` / `-SftpPort` / `-SftpUser` — where and who.
- `-SftpRemotePath` — the directory **on the server** to upload into. The bundle folder
  lands at `<remote-path>/gitlab-offline-bundle/`. **That** full path is what you pass to
  the Linux script as `--path` (see Part 3).
- `-SftpKey <file>` — optional private‑key file. Without it, `sftp` prompts for a password.

Already downloaded and only want to (re)upload?

```powershell
.\Download-GitLabAssets.ps1 -UploadOnly `
    -SftpHost 10.0.0.5 -SftpUser deploy -SftpRemotePath /srv/gitlab-bundle
```

> If SFTP isn't an option, just copy the whole `gitlab-offline-bundle/` folder to the
> server by any approved means (USB, file drop, `scp` within the LAN).

### The required upgrade path

You cannot jump straight from 16.1 to the latest release — GitLab mandates intermediate
"stops". The default path is in [`config/upgrade-path.conf`](config/upgrade-path.conf):

```
16.3.9 → 16.7.10 → 16.11.10 →
17.1.8 → 17.3.7 → 17.5.5 → 17.8.7 → 17.11.7 →
18.2.8 → 18.5.7 → 18.8.11 → 18.11.7 →
19.1.2 (latest)
```

The Linux script auto‑selects only the stops **above each server's detected version**,
so one bundle works for several servers. Confirm the path any time with the official
[GitLab upgrade‑path tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/).

> **OS availability (validated 2026‑07):** jammy — all stops; noble — packages start at
> 17.1.x; focal — `.deb` only up to 18.8.x (no 19.x; needs OS upgrade to jammy); EL 8 —
> all stops; Docker — host OS irrelevant.

---

# Part 3 — Upgrade on the offline server

Run the **one** command on the server. It detects the install type, figures out which
stops apply, **backs up first**, then upgrades through each required stop.

```bash
# Go to the uploaded bundle (the SFTP "remote path" + bundle folder):
cd /srv/gitlab-bundle/gitlab-offline-bundle
chmod +x gitlab-offline-upgrade.sh

# See exactly what will happen (no changes):
sudo ./gitlab-offline-upgrade.sh status --path /srv/gitlab-bundle/gitlab-offline-bundle

# Verify checksums, disk, and that every needed package is present:
sudo ./gitlab-offline-upgrade.sh preflight --path /srv/gitlab-bundle/gitlab-offline-bundle
```

`--path` (alias of `--bundle`) is the folder where the bundle was uploaded — the tool
looks **there** for the candidate package/image versions. If you `cd` into the bundle
folder you can omit it (it defaults to the script's own folder).

`status` prints the detected install type (**docker / omnibus‑deb / omnibus‑rpm**), the
current version, the exact stops it will apply, and whether each package (and the
rollback baseline) is present.

### Do the upgrade

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

For each stop the tool: installs the package / swaps the image → runs `gitlab-ctl
reconfigure` (schema migrations) → waits for services to be ready → **waits for batched
background migrations to finish** → then moves to the next stop. Skipping the
background‑migration wait is the most common way real upgrades corrupt data; this tool
blocks on it automatically.

The **docker** path preserves your container exactly: it reads the running container's
volumes, ports, hostname, restart policy and `GITLAB_OMNIBUS_CONFIG` via `docker
inspect`, prints the `docker run` it will execute (saved to `last-docker-run.txt`), and
reuses the same volumes so **no data is lost**. `docker compose`‑managed containers are
detected and upgraded by bumping the image tag and running `docker compose up -d`.

### If an upgrade fails — roll back (in place)

```bash
# Roll back to the automatic pre-upgrade backup:
sudo ./gitlab-offline-upgrade.sh rollback

# Roll back to a specific backup directory:
sudo ./gitlab-offline-upgrade.sh rollback --backup /var/opt/gitlab-offline-upgrade/backups/20260719-101500
```

Rollback reinstalls the **original version** (from the bundle — this is why you pass
`-CurrentVersion` when downloading), restores the original secrets/config, and restores
the pre‑upgrade backup. A rollback is only as good as that backup, which is why the tool
always takes one first.

### Verify

```bash
sudo ./gitlab-offline-upgrade.sh verify   # prints version, runs gitlab:check
```

---

## Command / option reference

| Command | Purpose |
|--------|---------|
| `status` | Detect install, show version + planned path + package presence. |
| `preflight` | Verify checksums, disk, and that all path packages exist. |
| `backup` | Full backup packed into **one portable file** (app data + secrets + config). |
| `restore` | Import a portable backup file into the GitLab installed here (migrate). |
| `upgrade` | Backup (unless `--skip-backup`) then step through the path. |
| `rollback` | Undo an in‑place upgrade (reinstall old version + restore its backup). |
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
| `--bundle DIR` / `--path DIR` | Bundle root — the SFTP remote path where the bundle landed. |
| `--work-dir DIR` | State/logs/backups root (default `/var/opt/gitlab-offline-upgrade`). |
| `--out FILE` | (backup) where to write the single portable backup file. |
| `--from FILE` | (restore) the portable backup file to import. |
| `--backup DIR` | (rollback/restore) a backup directory to use. |

Every script also has `--help`.

---

## End‑to‑end example (16.1.8 deb server → latest)

```powershell
# --- ONLINE Windows PC ---
cd windows
.\Download-GitLabAssets.ps1 -CurrentVersion 16.1.8 -Validate           # 1. check path
.\Download-GitLabAssets.ps1 -CurrentVersion 16.1.8 -Codename jammy `    # 2. download + push
    -SftpHost 10.0.0.5 -SftpUser deploy -SftpRemotePath /srv/gitlab-bundle
```

```bash
# --- OFFLINE GitLab server ---
cd /srv/gitlab-bundle/gitlab-offline-bundle
chmod +x gitlab-offline-upgrade.sh
sudo ./gitlab-offline-upgrade.sh preflight     # 3. verify the bundle is complete
sudo ./gitlab-offline-upgrade.sh upgrade       # 4. auto-backup, then upgrade to latest
sudo ./gitlab-offline-upgrade.sh verify        # 5. confirm health
```

---

## Important assumptions & caveats

- **Test on staging first.** Clone the instance and rehearse the full path before
  touching production. GitLab upgrades run **irreversible** database migrations.
- **Downtime.** Each stop restarts GitLab and runs migrations; the instance is
  unavailable during the run.
- **Disk.** Keep ≥20 GB free on `/var/opt/gitlab` (deb/rpm) or `/var/lib/docker`
  (docker) for backups and migrations. `preflight` checks this.
- **Secrets are non‑negotiable.** Keep the portable backup file (which contains
  `gitlab-secrets.json`) somewhere safe and off the server.
- **Restore needs a matching version.** Install the same GitLab version on the
  destination before `restore`. Rollback also needs the original version's package in
  the bundle (download with `-CurrentVersion`).
- **Custom backup paths.** The tool assumes the default `/var/opt/gitlab/backups`. If
  you set a custom `gitlab_rails['backup_path']`, adjust accordingly.
- **The path is data, not code.** Confirm it with the official upgrade‑path tool and
  always use the *latest patch* of each required minor.
