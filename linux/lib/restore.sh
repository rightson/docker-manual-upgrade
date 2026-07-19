#!/usr/bin/env bash
# =============================================================================
# restore.sh - roll back to a pre-upgrade backup.
#
# GitLab does NOT support downgrading in place: once migrations run the schema
# is newer than the old binaries. The only reliable rollback is:
#   1. Put the ORIGINAL binaries/image back (same version the backup came from).
#   2. Restore the ORIGINAL secrets/config.
#   3. Restore the application-data backup with `gitlab-backup restore`.
# =============================================================================

# Resolve which backup directory to use. Honours $ROLLBACK_BACKUP (--backup).
pick_backup_dir() {
  local root="$1"
  if [[ -n "${ROLLBACK_BACKUP:-}" ]]; then
    if [[ -d "$ROLLBACK_BACKUP" ]]; then echo "$ROLLBACK_BACKUP"; return 0; fi
    if [[ -d "$root/$ROLLBACK_BACKUP" ]]; then echo "$root/$ROLLBACK_BACKUP"; return 0; fi
    die "Backup '$ROLLBACK_BACKUP' not found under $root."
  fi
  if [[ -f "$root/.last_backup_path" ]]; then
    cat "$root/.last_backup_path"; return 0
  fi
  [[ -L "$root/latest" ]] && { readlink -f "$root/latest"; return 0; }
  die "No backup specified and no latest backup found in $root (use --backup <dir>)."
}

# Shared: restore app data from a backup name using the (already-correct-version) instance.
gl_restore_appdata() {
  local app_backup="$1"
  info "Stopping services that hold the database open (puma, sidekiq)..."
  gl_exec gitlab-ctl stop puma    || warn "stop puma returned non-zero"
  gl_exec gitlab-ctl stop sidekiq || warn "stop sidekiq returned non-zero"
  info "Restoring application data (BACKUP=$app_backup). This is destructive and can take a while..."
  gl_exec gitlab-backup restore "BACKUP=$app_backup" force=yes \
    || die "gitlab-backup restore failed."
  info "Reconfiguring and restarting..."
  gl_exec gitlab-ctl reconfigure || warn "reconfigure returned non-zero"
  gl_exec gitlab-ctl restart     || warn "restart returned non-zero"
}

# --- deb rollback -------------------------------------------------------------
restore_deb() {
  local dir="$1" bk_version="$2" app_backup="$3"
  local deb; deb="$(EDITION=$GL_EDITION; deb_path "$bk_version")"

  # 1. Reinstall the original version if the current binaries differ.
  local cur; cur="$(deb_installed_version || echo unknown)"
  if [[ "$cur" != "$bk_version" ]]; then
    [[ -f "$deb" ]] || die "Need the original package to roll back to $bk_version but it is missing: $deb"
    info "Reinstalling original GitLab $bk_version (current is $cur)..."
    gitlab-ctl stop >/dev/null 2>&1 || true
    if ! DEBIAN_FRONTEND=noninteractive dpkg -i --force-confold --force-confdef "$deb"; then
      warn "Plain install failed (likely a downgrade); retrying with --force-downgrade."
      DEBIAN_FRONTEND=noninteractive dpkg -i --force-downgrade --force-confold --force-confdef "$deb" \
        || die "Could not reinstall $bk_version."
    fi
  fi

  # 2. Restore secrets/config BEFORE reconfigure so encrypted data matches.
  info "Restoring gitlab-secrets.json and gitlab.rb from backup..."
  [[ -f "$dir/gitlab-secrets.json" ]] && cp -a "$dir/gitlab-secrets.json" /etc/gitlab/gitlab-secrets.json
  [[ -f "$dir/gitlab.rb"           ]] && cp -a "$dir/gitlab.rb"           /etc/gitlab/gitlab.rb
  gitlab-ctl reconfigure || die "reconfigure failed after restoring secrets."
  gl_wait_ready 1800 || die "GitLab did not come up on $bk_version."

  # 3. Restore application data.
  gl_restore_appdata "$app_backup"

  info "Running integrity checks..."
  gitlab-rake gitlab:check SANITIZE=true || warn "gitlab:check reported issues (review above)."
  gitlab-rake gitlab:doctor:secrets      || warn "doctor:secrets reported issues (review above)."
}

# --- docker rollback ----------------------------------------------------------
restore_docker() {
  local dir="$1" bk_version="$2" app_backup="$3"
  local oldimg tar; oldimg="$(EDITION=$GL_EDITION; image_ref "$bk_version")"; tar="$(EDITION=$GL_EDITION; image_tar "$bk_version")"

  # 1. Ensure the original image is available and recreate the container on it.
  if ! docker image inspect "$oldimg" >/dev/null 2>&1; then
    [[ -f "$tar" ]] || die "Need original image $oldimg to roll back but archive is missing: $tar"
    info "Loading original image $oldimg..."
    docker load -i "$tar" || die "docker load failed."
  fi
  info "Recreating container on original image $oldimg (data volumes are preserved)..."
  docker_recreate "$GL_CONTAINER" "$oldimg" "$GL_CONTAINER"

  # 2. Restore secrets/config into the /etc/gitlab volume, then reconfigure.
  info "Restoring gitlab-secrets.json and gitlab.rb into the container..."
  [[ -f "$dir/gitlab-secrets.json" ]] && docker cp "$dir/gitlab-secrets.json" "$GL_CONTAINER:/etc/gitlab/gitlab-secrets.json"
  [[ -f "$dir/gitlab.rb"           ]] && docker cp "$dir/gitlab.rb"           "$GL_CONTAINER:/etc/gitlab/gitlab.rb"
  gl_exec gitlab-ctl reconfigure || die "reconfigure failed after restoring secrets."
  gl_wait_ready 2400 || die "Container did not come up on $bk_version."

  # 3. Restore application data (the tar lives in the persisted backups volume).
  gl_restore_appdata "$app_backup"

  info "Running integrity checks..."
  gl_exec gitlab-rake gitlab:check SANITIZE=true || warn "gitlab:check reported issues (review above)."
}

# --- entry point --------------------------------------------------------------
do_rollback() {
  local root="$1"
  require_root
  local dir; dir="$(pick_backup_dir "$root")"
  [[ -f "$dir/metadata.env" ]] || die "No metadata.env in $dir; cannot roll back safely."
  # shellcheck disable=SC1090
  source "$dir/metadata.env"

  # metadata.env sets GL_TYPE/GL_EDITION/GL_VERSION/APP_BACKUP/GL_CONTAINER
  local bk_type="$GL_TYPE" bk_edition="$GL_EDITION" bk_version="$GL_VERSION" app_backup="$APP_BACKUP"

  step "ROLLBACK to pre-upgrade backup"
  info "Backup dir   : $dir"
  info "Type/edition : $bk_type/$bk_edition"
  info "Restore to   : GitLab $bk_version"
  info "App backup   : ${app_backup}_gitlab_backup.tar"
  warn "This will OVERWRITE the current GitLab database, repositories and uploads"
  warn "with the backup taken at $BACKUP_TIMESTAMP. Current data since then is lost."
  confirm "Proceed with rollback?" || die "Rollback aborted."

  # Re-detect the live install so GL_CONTAINER points at the current container.
  FORCE_TYPE="$bk_type"; GL_EDITION="$bk_edition"
  [[ "$bk_type" == docker && -n "$GL_CONTAINER" ]] && export GL_CONTAINER
  detect_gitlab
  GL_EDITION="$bk_edition"   # trust the backup's edition

  if [[ "$bk_type" == deb ]]; then
    restore_deb "$dir" "$bk_version" "$app_backup"
  else
    restore_docker "$dir" "$bk_version" "$app_backup"
  fi

  step "Rollback complete"
  ok "GitLab restored to $bk_version from backup $BACKUP_TIMESTAMP."
  info "Log in and verify projects, users and CI/CD variables before resuming use."
}
