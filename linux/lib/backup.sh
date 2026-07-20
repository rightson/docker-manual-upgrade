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
#     metadata.env            (type, edition, version, app backup name, ...)
#     gitlab-secrets.json
#     gitlab.rb
#     app-backup.txt          (name/path of the gitlab-backup tar)
#     container-inspect.json  (docker only: original run config for rollback)

backup_metadata_write() {
  local dir="$1" app_backup="$2"
  cat >"$dir/metadata.env" <<EOF
# GitLab offline-upgrade backup metadata
BACKUP_TIMESTAMP=$BACKUP_TS
GL_TYPE=$GL_TYPE
GL_EDITION=$GL_EDITION
GL_VERSION=$GL_VERSION
GL_CONTAINER=${GL_CONTAINER:-}
APP_BACKUP=$app_backup
HOSTNAME=$(hostname)
EOF
  ok "Wrote backup metadata: $dir/metadata.env"
}

# --- app-data backup ----------------------------------------------------------
# Sets the global APP_BACKUP to the backup name (minus _gitlab_backup.tar).
backup_app_data() {
  APP_BACKUP=""
  step "Creating application-data backup (gitlab-backup create)"
  info "This can take a long time on large instances. Do not interrupt."
  gl_exec gitlab-backup create CRON=0 || die "gitlab-backup create failed."
  # Locate the newest backup tar (in the container or on the host).
  local newest
  newest=$(gl_sh 'ls -1t /var/opt/gitlab/backups/*_gitlab_backup.tar 2>/dev/null | head -1')
  [[ -n "$newest" ]] || die "gitlab-backup create reported success but no backup tar was found."
  APP_BACKUP="$(basename "$newest")"
  APP_BACKUP="${APP_BACKUP%_gitlab_backup.tar}"
  ok "Application backup: $newest"
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
# Args: backup_root_dir
do_backup() {
  local root="$1"
  require_root
  BACKUP_TS="$(date '+%Y%m%d-%H%M%S')"
  local dir="$root/$BACKUP_TS"
  mkdir -p "$dir"

  step "GitLab backup starting -> $dir"
  print_detection

  # Preflight: make sure GitLab is up before we trust a backup.
  gl_wait_ready 600 || die "GitLab is not healthy; refusing to back up an unhealthy instance."

  backup_app_data                 # sets global APP_BACKUP
  backup_config_secrets "$dir"
  backup_docker_runspec "$dir"
  backup_metadata_write "$dir" "$APP_BACKUP"

  # Convenience pointer to the latest backup.
  ln -sfn "$dir" "$root/latest"

  step "Backup complete"
  ok "Backup directory : $dir"
  ok "App data backup  : ${APP_BACKUP}_gitlab_backup.tar (in /var/opt/gitlab/backups)"
  info "Keep the ENTIRE backup directory safe. Rollback needs both the app tar"
  info "AND gitlab-secrets.json from this directory."
  echo "$dir" >"$root/.last_backup_path"
}
