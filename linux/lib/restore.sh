#!/usr/bin/env bash
# =============================================================================
# restore.sh - two related but distinct operations:
#
#   * rollback (do_rollback) - UNDO an in-place upgrade on the SAME host. It
#     reinstalls the ORIGINAL version's binaries/image from the bundle, then
#     restores that host's own pre-upgrade backup. GitLab cannot downgrade in
#     place, so this is the only supported way to revert an upgrade.
#
#   * restore  (do_restore)  - IMPORT a single portable backup file (produced by
#     the `backup` command) into the GitLab that is ALREADY installed on THIS
#     host - which may be a DIFFERENT, freshly-installed machine. This is the
#     backup/migrate-to-another-server flow. GitLab requires the target to run
#     the SAME version as the backup, so install that version first, then run
#     `restore --from <file>`.
#
# Both ultimately call `gitlab-backup restore` after putting the original
# secrets/config in place so encrypted data (2FA, tokens, CI/CD vars) decrypts.
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
# Handles both deb and rpm Omnibus rollbacks ($pm = deb|rpm).
restore_package() {
  local dir="$1" bk_version="$2" app_backup="$3" pm="$4"

  # 1. Reinstall the original version if the current binaries differ.
  local cur; cur="$(omnibus_installed_version || echo unknown)"
  if [[ "$cur" != "$bk_version" ]]; then
    if [[ "$pm" == deb ]]; then
      local deb; deb="$(EDITION=$GL_EDITION; deb_path "$bk_version")"
      [[ -f "$deb" ]] || die "Need the original .deb to roll back to $bk_version but it is missing: $deb"
      info "Reinstalling original GitLab $bk_version (current is $cur)..."
      gitlab-ctl stop >/dev/null 2>&1 || true
      if ! DEBIAN_FRONTEND=noninteractive dpkg -i --force-confold --force-confdef "$deb"; then
        warn "Plain install failed (likely a downgrade); retrying with --force-downgrade."
        DEBIAN_FRONTEND=noninteractive dpkg -i --force-downgrade --force-confold --force-confdef "$deb" \
          || die "Could not reinstall $bk_version."
      fi
    else
      local rpm_file; rpm_file="$(EDITION=$GL_EDITION; EL_VERSION=${EL_VERSION:-8}; rpm_path "$bk_version")"
      [[ -f "$rpm_file" ]] || die "Need the original .rpm to roll back to $bk_version but it is missing: $rpm_file"
      info "Reinstalling original GitLab $bk_version (current is $cur)..."
      gitlab-ctl stop >/dev/null 2>&1 || true
      # --oldpackage permits the downgrade back to the backup's version.
      rpm -Uvh --oldpackage "$rpm_file" || die "Could not reinstall $bk_version."
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

  case "$bk_type" in
    deb|rpm) restore_package "$dir" "$bk_version" "$app_backup" "$bk_type" ;;
    docker)  restore_docker  "$dir" "$bk_version" "$app_backup" ;;
    *)       die "Unknown backup type '$bk_type'." ;;
  esac

  step "Rollback complete"
  ok "GitLab restored to $bk_version from backup $BACKUP_TIMESTAMP."
  info "Log in and verify projects, users and CI/CD variables before resuming use."
}

# =============================================================================
# restore (migration): import a portable backup file into THIS host's GitLab.
# =============================================================================

# Resolve the restore source to an unpacked backup DIRECTORY. Accepts:
#   --from <archive.tar.gz>  (RESTORE_FROM)  - a single portable backup file
#   --backup <dir|archive>   (ROLLBACK_BACKUP)
#   (nothing)                                - the last portable backup made here
# Prints the directory path on stdout.
resolve_restore_source() {
  local root="$1" src=""
  src="${RESTORE_FROM:-}"
  [[ -z "$src" && -n "${ROLLBACK_BACKUP:-}" ]] && src="$ROLLBACK_BACKUP"
  if [[ -z "$src" && -f "$root/.last_portable_backup" ]]; then
    src="$(cat "$root/.last_portable_backup")"
  fi
  [[ -n "$src" ]] || die "Nothing to restore. Pass --from <backup-file.tar.gz> (or --backup <dir>)."

  # A directory is used as-is.
  if [[ -d "$src" ]]; then echo "$src"; return 0; fi
  [[ -f "$src" ]] || die "Restore source not found: $src"

  # A file: unpack the portable archive to a temp dir under the work dir.
  local tmp="$root/.restore-extract/$BACKUP_TS"
  mkdir -p "$tmp"
  info "Extracting portable backup: $src"
  tar -C "$tmp" -xzf "$src" || die "Failed to extract $src (is it a gitlab-offline-upgrade backup file?)."
  local inner
  inner="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "$inner" && -f "$inner/metadata.env" ]] \
    || die "Archive '$src' does not contain a valid backup (no metadata.env inside)."
  echo "$inner"
}

# Put the app-data tar from the backup dir into THIS host's backups directory,
# owned by git, so gitlab-backup restore can find it.
place_app_tar() {
  local dir="$1" app_backup="$2"
  local fname="${app_backup}_gitlab_backup.tar"
  [[ -f "$dir/$fname" ]] || die \
"This backup has no app-data tar ($fname) inside it. It was taken in 'light'
 (pre-upgrade) mode and can only be used for an in-place rollback, not a
 restore to another host. Re-create it with the 'backup' command."
  step "Placing the application-data tar into this host's backups directory"
  if [[ "$GL_TYPE" == docker ]]; then
    docker exec "$GL_CONTAINER" mkdir -p /var/opt/gitlab/backups
    docker cp "$dir/$fname" "$GL_CONTAINER:/var/opt/gitlab/backups/$fname" \
      || die "docker cp of the app-data tar into the container failed."
    docker exec "$GL_CONTAINER" chown git:git "/var/opt/gitlab/backups/$fname" \
      || warn "Could not chown the tar to git:git (continuing)."
  else
    mkdir -p /var/opt/gitlab/backups
    cp -a "$dir/$fname" "/var/opt/gitlab/backups/$fname" \
      || die "Copying the app-data tar into /var/opt/gitlab/backups failed."
    chown git:git "/var/opt/gitlab/backups/$fname" 2>/dev/null \
      || warn "Could not chown the tar to git:git (continuing)."
  fi
  ok "Placed $fname"
}

# Restore secrets + config into the CURRENT install, then reconfigure.
restore_secrets_config() {
  local dir="$1"
  step "Restoring gitlab-secrets.json and gitlab.rb"
  if [[ "$GL_TYPE" == docker ]]; then
    [[ -f "$dir/gitlab-secrets.json" ]] && docker cp "$dir/gitlab-secrets.json" "$GL_CONTAINER:/etc/gitlab/gitlab-secrets.json"
    [[ -f "$dir/gitlab.rb"           ]] && docker cp "$dir/gitlab.rb"           "$GL_CONTAINER:/etc/gitlab/gitlab.rb"
    gl_exec gitlab-ctl reconfigure || die "reconfigure failed after restoring secrets."
  else
    [[ -f "$dir/gitlab-secrets.json" ]] && cp -a "$dir/gitlab-secrets.json" /etc/gitlab/gitlab-secrets.json
    [[ -f "$dir/gitlab.rb"           ]] && cp -a "$dir/gitlab.rb"           /etc/gitlab/gitlab.rb
    gitlab-ctl reconfigure || die "reconfigure failed after restoring secrets."
  fi
  gl_wait_ready 1800 || die "GitLab did not come up after restoring secrets/config."
}

# --- entry point --------------------------------------------------------------
# Import a portable backup into whatever GitLab is installed on THIS host.
do_restore() {
  local root="$1"
  require_root
  BACKUP_TS="$(date '+%Y%m%d-%H%M%S')"   # used to name the temp extraction dir
  local dir; dir="$(resolve_restore_source "$root")"
  [[ -f "$dir/metadata.env" ]] || die "No metadata.env in $dir; not a valid backup."
  # shellcheck disable=SC1090
  # Keep the operator's explicit --container (if any) BEFORE metadata.env
  # clobbers GL_CONTAINER with the SOURCE host's container name.
  local user_container="${GL_CONTAINER:-}"
  # shellcheck disable=SC1090
  source "$dir/metadata.env"
  local bk_type="$GL_TYPE" bk_edition="$GL_EDITION" bk_version="$GL_VERSION" app_backup="$APP_BACKUP"

  step "RESTORE a portable backup onto this host"
  info "Backup source : $dir"
  info "Backup is     : $bk_type/$bk_edition   GitLab $bk_version   (from ${HOSTNAME:-unknown}, $BACKUP_TIMESTAMP)"

  # The target GitLab must ALREADY be installed here (possibly a fresh machine).
  # Reset GL_CONTAINER to the operator's override (or empty) so detection finds
  # THIS host's container instead of the source host's name from metadata.
  GL_CONTAINER="$user_container"
  detect_gitlab
  print_detection
  local cur="$GL_VERSION"

  # Install-type sanity.
  if [[ "$GL_TYPE" != "$bk_type" ]]; then
    warn "This host is a '$GL_TYPE' install but the backup came from '$bk_type'."
    warn "Restoring across install types works only if the GitLab VERSION matches exactly."
  fi
  # GitLab only restores a backup into the SAME version.
  if [[ "$cur" != "$bk_version" ]]; then
    warn "Installed GitLab is $cur but this backup is from $bk_version."
    warn "GitLab can ONLY restore a backup into an install running the SAME version."
    warn "Install GitLab $bk_version on this host first, then re-run:"
    warn "    sudo ./gitlab-offline-upgrade.sh restore --from <backup-file.tar.gz>"
    confirm "Continue anyway (NOT recommended - restore will likely fail)?" || die "Aborted."
  fi

  warn "This will OVERWRITE the database, repositories and uploads on THIS host"
  warn "with the data from the backup. Any existing data here is lost."
  confirm "Proceed with the restore?" || die "Restore aborted."

  place_app_tar "$dir" "$app_backup"
  restore_secrets_config "$dir"
  gl_restore_appdata "$app_backup"

  info "Running integrity checks..."
  gl_exec gitlab-rake gitlab:check SANITIZE=true || warn "gitlab:check reported issues (review above)."
  gl_exec gitlab-rake gitlab:doctor:secrets      || warn "doctor:secrets reported issues (review above)."

  step "Restore complete"
  ok "Restored GitLab $bk_version data onto this host."
  info "Log in and verify projects, users, and CI/CD variables before going live."
}
