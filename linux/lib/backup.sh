#!/usr/bin/env bash
# =============================================================================
# backup.sh - full, restorable backup of a GitLab instance BEFORE upgrading.
#
# A complete GitLab backup is TWO parts:
#   1. Application data  -> `gitlab-backup create` (DB, repos, uploads, ...)
#   2. Configuration/secrets -> /etc/gitlab/gitlab-secrets.json + gitlab.rb
#      Without gitlab-secrets.json the encrypted data (2FA, CI/CD variables,
#      tokens) in the app backup CANNOT be decrypted after a restore.
# Both are required for a working rollback.
# =============================================================================

# Directory layout produced:
#   <backup-dir>/<timestamp>/
#     metadata.env                       (type, edition, version, app tar name)
#     gitlab-secrets.json
#     gitlab.rb
#     etc-gitlab.tar.gz                  (the full /etc/gitlab)
#     <name>_gitlab_backup.tar           (portable mode only: the app-data tar)
#     container-inspect.json             (docker only: original run config)
#
# Two modes:
#   portable (default, used by the `backup` command) - copies the app-data tar
#            INTO the backup dir and then packs the whole dir into ONE
#            self-contained .tar.gz file that can be carried to, and restored
#            on, a DIFFERENT GitLab host (see restore.sh / the `restore` cmd).
#   light    (used internally before an upgrade) - leaves the app-data tar in
#            /var/opt/gitlab/backups (fine for an in-place rollback) and skips
#            the single-file packing to save time and disk.

backup_metadata_write() {
  local dir="$1" app_backup="$2"
  cat >"$dir/metadata.env" <<EOF
# GitLab offline-upgrade backup metadata
BACKUP_TIMESTAMP=$BACKUP_TS
GL_TYPE=$GL_TYPE
GL_EDITION=$GL_EDITION
GL_VERSION=$GL_VERSION
GL_CONTAINER=${GL_CONTAINER:-}
CODENAME=${CODENAME:-}
EL_VERSION=${EL_VERSION:-}
APP_BACKUP=$app_backup
HOSTNAME=$(hostname)
EOF
  ok "Wrote backup metadata: $dir/metadata.env"
}

# --- app-data backup ----------------------------------------------------------
# Sets the global APP_BACKUP to the backup name (minus _gitlab_backup.tar) and
# APP_TAR_SRC to the tar's path as seen from the GitLab install (host or in the
# container - both use /var/opt/gitlab/backups).
backup_app_data() {
  APP_BACKUP=""; APP_TAR_SRC=""
  step "Creating application-data backup (gitlab-backup create)"
  info "This can take a long time on large instances. Do not interrupt."
  gl_exec gitlab-backup create CRON=0 || die "gitlab-backup create failed."
  # Locate the newest backup tar (in the container or on the host).
  local newest
  newest=$(gl_sh 'ls -1t /var/opt/gitlab/backups/*_gitlab_backup.tar 2>/dev/null | head -1')
  [[ -n "$newest" ]] || die "gitlab-backup create reported success but no backup tar was found."
  APP_TAR_SRC="$newest"
  APP_BACKUP="$(basename "$newest")"
  APP_BACKUP="${APP_BACKUP%_gitlab_backup.tar}"
  ok "Application backup: $newest"
}

# Copy the application-data tar INTO the backup dir so the dir is fully
# self-contained (required to restore on another host). portable mode only.
collect_app_tar() {
  local dir="$1"
  local fname="${APP_BACKUP}_gitlab_backup.tar"
  step "Adding the application-data tar to the portable backup"
  info "Copying $fname (this is the big one; needs free disk = backup size)..."
  if [[ "$GL_TYPE" == docker ]]; then
    docker cp "$GL_CONTAINER:/var/opt/gitlab/backups/$fname" "$dir/$fname" \
      || die "Could not copy the app-data tar out of the container."
  else
    cp -a "/var/opt/gitlab/backups/$fname" "$dir/$fname" \
      || die "Could not copy the app-data tar from /var/opt/gitlab/backups."
  fi
  ok "Included $fname ($(hsize "$dir/$fname"))"
}

# Pack the whole backup dir into ONE portable .tar.gz file.
make_portable_archive() {
  local dir="$1" out="$2"
  step "Packing everything into a single portable backup file"
  local parent base; parent="$(dirname "$dir")"; base="$(basename "$dir")"
  mkdir -p "$(dirname "$out")"
  tar -C "$parent" -czf "$out" "$base" || die "Failed to create portable archive: $out"
  ok "Single portable backup file: $out ($(hsize "$out"))"
}

# --- config/secrets backup ----------------------------------------------------
backup_config_secrets() {
  local dir="$1"
  step "Backing up configuration and secrets (/etc/gitlab)"
  local f found=0
  for f in gitlab-secrets.json gitlab.rb; do
    if [[ "$GL_TYPE" == docker ]]; then
      if docker cp "$GL_CONTAINER:/etc/gitlab/$f" "$dir/$f" 2>/dev/null; then
        ok "Saved $f"; found=1
      else
        warn "Could not copy /etc/gitlab/$f from container."
      fi
    else
      if [[ -r "/etc/gitlab/$f" ]]; then
        cp -a "/etc/gitlab/$f" "$dir/$f"; ok "Saved $f"; found=1
      else
        warn "Could not read /etc/gitlab/$f"
      fi
    fi
  done
  # Also archive the entire /etc/gitlab for completeness (ssl, custom hooks...).
  if [[ "$GL_TYPE" == docker ]]; then
    docker cp "$GL_CONTAINER:/etc/gitlab/." "$dir/etc-gitlab" 2>/dev/null && \
      tar -C "$dir" -czf "$dir/etc-gitlab.tar.gz" etc-gitlab 2>/dev/null && rm -rf "$dir/etc-gitlab"
  else
    tar -C /etc -czf "$dir/etc-gitlab.tar.gz" gitlab 2>/dev/null
  fi
  [[ -f "$dir/etc-gitlab.tar.gz" ]] && ok "Archived full /etc/gitlab -> etc-gitlab.tar.gz"
  [[ "$found" == 1 ]] || die "Failed to back up gitlab-secrets.json / gitlab.rb; aborting (rollback would be impossible)."
}

# --- docker run-spec capture (needed to recreate the container on rollback) ---
backup_docker_runspec() {
  local dir="$1"
  [[ "$GL_TYPE" == docker ]] || return 0
  docker inspect "$GL_CONTAINER" >"$dir/container-inspect.json" 2>/dev/null \
    && ok "Captured container run configuration -> container-inspect.json"
}

# --- entry point --------------------------------------------------------------
# Args: backup_root_dir  [mode: portable|light]   (default portable)
# portable -> also copies the app tar in and packs a single .tar.gz file.
# light    -> pre-upgrade backup used for in-place rollback (no packing).
do_backup() {
  local root="$1" mode="${2:-portable}"
  require_root
  BACKUP_TS="$(date '+%Y%m%d-%H%M%S')"
  local dir="$root/$BACKUP_TS"
  mkdir -p "$dir"

  step "GitLab backup starting -> $dir  (mode: $mode)"
  print_detection

  # Preflight: make sure GitLab is up before we trust a backup.
  gl_wait_ready 600 || die "GitLab is not healthy; refusing to back up an unhealthy instance."

  backup_app_data                 # sets globals APP_BACKUP, APP_TAR_SRC
  backup_config_secrets "$dir"
  backup_docker_runspec "$dir"
  [[ "$mode" == portable ]] && collect_app_tar "$dir"
  backup_metadata_write "$dir" "$APP_BACKUP"

  # Convenience pointer to the latest backup.
  ln -sfn "$dir" "$root/latest"
  echo "$dir" >"$root/.last_backup_path"

  if [[ "$mode" == portable ]]; then
    local out
    out="${BACKUP_OUT:-$root/gitlab-backup-$(hostname -s 2>/dev/null || hostname)-${GL_VERSION}-${BACKUP_TS}.tar.gz}"
    make_portable_archive "$dir" "$out"
    echo "$out" >"$root/.last_portable_backup"
    step "Backup complete"
    ok  "ONE portable backup file : $out"
    info "Carry THIS single file to the other GitLab host and run:"
    info "    sudo ./gitlab-offline-upgrade.sh restore --from $(basename "$out")"
    info "The working copy is also kept unpacked at: $dir"
  else
    step "Backup complete"
    ok  "Backup directory : $dir"
    ok  "App data backup  : ${APP_BACKUP}_gitlab_backup.tar (in /var/opt/gitlab/backups)"
    info "This is a pre-upgrade backup for in-place rollback on THIS host."
  fi
}
