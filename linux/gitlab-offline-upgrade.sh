#!/usr/bin/env bash
# =============================================================================
# gitlab-offline-upgrade.sh
#
# One script to back up, upgrade (through every required stop), verify and
# roll back an OFFLINE GitLab server - whether it runs from the Omnibus .deb
# package or from a Docker image. Uses only assets already downloaded into the
# bundle by the Windows-side downloader (no internet access required here).
#
# Usage:
#   sudo ./gitlab-offline-upgrade.sh <command> [options]
#
# Commands:
#   status            Detect the install, show version and the planned path.
#   preflight         Verify the bundle has every package/image the path needs.
#   backup            Take a full, restorable backup (app data + secrets).
#   upgrade           Backup (unless --skip-backup) then step through the path.
#   rollback          Restore a previous backup (undo an upgrade).
#   verify            Post-upgrade health checks.
#
# Common options:
#   --type deb|docker|auto   Force the install type (default: auto-detect).
#   --edition ce|ee          GitLab edition (default: auto/ce).
#   --container NAME         Docker container name (default: auto-detect).
#   --to VERSION             Stop upgrading once VERSION is reached.
#   --step                   Apply only the next single required stop, then stop.
#   --yes                    Do not prompt for confirmation (unattended).
#   --skip-backup            (upgrade) skip the automatic pre-upgrade backup.
#   --bundle DIR             Bundle root (default: this script's directory).
#   --work-dir DIR           State/logs/backups root (default: /var/opt/gitlab-offline-upgrade).
#   --backup DIR             (rollback) which backup directory to restore.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- defaults / globals ------------------------------------------------------
FORCE_TYPE="auto"
GL_EDITION=""
GL_CONTAINER=""
TARGET_OVERRIDE=""
STEP_ONLY=0
ASSUME_YES=0
SKIP_BACKUP=0
BUNDLE_DIR="$SCRIPT_DIR"
WORK_DIR="/var/opt/gitlab-offline-upgrade"
ROLLBACK_BACKUP=""
export FORCE_TYPE GL_EDITION GL_CONTAINER ASSUME_YES

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---- parse args --------------------------------------------------------------
[[ $# -ge 1 ]] || { usage; exit 1; }
COMMAND="$1"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)      FORCE_TYPE="$2"; shift 2;;
    --edition)   GL_EDITION="$2"; EDITION="$2"; shift 2;;
    --container) GL_CONTAINER="$2"; shift 2;;
    --to)        TARGET_OVERRIDE="$2"; shift 2;;
    --step)      STEP_ONLY=1; shift;;
    --yes|-y)    ASSUME_YES=1; shift;;
    --skip-backup) SKIP_BACKUP=1; shift;;
    --bundle)    BUNDLE_DIR="$(cd "$2" && pwd)"; shift 2;;
    --work-dir)  WORK_DIR="$2"; shift 2;;
    --backup)    ROLLBACK_BACKUP="$2"; shift 2;;
    -h|--help)   usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done
export FORCE_TYPE GL_EDITION GL_CONTAINER ASSUME_YES BUNDLE_DIR SCRIPT_DIR WORK_DIR ROLLBACK_BACKUP

# ---- work dir + logging ------------------------------------------------------
mkdir -p "$WORK_DIR/logs" "$WORK_DIR/backups"
LOG_FILE="$WORK_DIR/logs/${COMMAND}-$(date '+%Y%m%d-%H%M%S').log"
export LOG_FILE

# ---- load libraries ----------------------------------------------------------
for lib in common detect backup restore upgrade_deb upgrade_docker; do
  f="$SCRIPT_DIR/lib/$lib.sh"
  [[ -f "$f" ]] || { echo "Missing library: $f" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$f"
done

if [[ "$COMMAND" == "help" || "$COMMAND" == "-h" || "$COMMAND" == "--help" ]]; then
  usage; exit 0
fi

load_bundle_conf
[[ -n "$GL_EDITION" ]] && EDITION="$GL_EDITION"

# ---- helpers -----------------------------------------------------------------
resolved_target() {
  if [[ -n "$TARGET_OVERRIDE" ]]; then echo "$TARGET_OVERRIDE"; else echo "$TARGET_VERSION"; fi
}

# asset for a version exists for the active install type?
asset_present() {
  local v="$1"
  if [[ "$GL_TYPE" == docker ]]; then [[ -f "$(image_tar "$v")" ]]
  else [[ -f "$(deb_path "$v")" ]]; fi
}

print_plan() {
  local target; target="$(resolved_target)"
  local pending; pending="$(compute_pending_stops "$GL_VERSION" "$target")"
  step "Upgrade plan"
  info "Current version : $GL_VERSION"
  info "Target version  : $target"
  info "Edition         : $EDITION   Codename(deb): $CODENAME"
  if [[ -z "$pending" ]]; then
    ok "Already at or beyond the target; nothing to do."
    return 0
  fi
  info "Required stops (in order):"
  local v miss=0
  while read -r v; do
    [[ -z "$v" ]] && continue
    if asset_present "$v"; then
      printf '   %s %s\n' "${C_GRN}✓${C_RST}" "$v" >&2
    else
      printf '   %s %s  (MISSING asset)\n' "${C_RED}✗${C_RST}" "$v" >&2; miss=1
    fi
  done <<<"$pending"
  # rollback baseline (current version asset)
  if asset_present "$GL_VERSION"; then
    info "Rollback baseline present: $GL_VERSION"
  else
    warn "Rollback baseline asset for CURRENT version $GL_VERSION is NOT in the bundle."
    warn "Rollback would require re-adding it. Re-run the downloader with -CurrentVersion $GL_VERSION."
  fi
  [[ "$miss" == 1 ]] && return 1 || return 0
}

# ---- commands ----------------------------------------------------------------
cmd_status() {
  detect_gitlab
  print_detection
  print_plan || true
}

cmd_preflight() {
  detect_gitlab
  print_detection
  step "Preflight checks"
  # bundle integrity
  if [[ -f "$BUNDLE_DIR/SHA256SUMS" ]]; then
    info "Verifying asset checksums (SHA256SUMS)..."
    ( cd "$BUNDLE_DIR" && sha256sum -c --quiet SHA256SUMS ) \
      && ok "All checksums match." || die "Checksum verification failed; re-transfer the bundle."
  else
    warn "No SHA256SUMS file in bundle; skipping integrity check."
  fi
  # disk
  if [[ "$GL_TYPE" == docker ]]; then check_disk_gb "/var/lib/docker" 20 || true
  else check_disk_gb "/var/opt/gitlab" 20 || true; fi
  # path assets
  print_plan
}

cmd_backup() {
  detect_gitlab
  do_backup "$WORK_DIR/backups"
}

cmd_upgrade() {
  detect_gitlab
  print_detection
  print_plan || die "One or more required assets are missing; aborting. Run 'preflight' after fixing the bundle."

  local target pending
  target="$(resolved_target)"
  pending="$(compute_pending_stops "$GL_VERSION" "$target")"
  [[ -n "$pending" ]] || { ok "Nothing to upgrade."; return 0; }

  if [[ "$SKIP_BACKUP" == 1 ]]; then
    warn "--skip-backup given: NO pre-upgrade backup will be taken. Rollback will be impossible."
    confirm "Really upgrade without a backup?" || die "Aborted."
  else
    do_backup "$WORK_DIR/backups"
  fi

  confirm "Begin upgrading $GL_VERSION -> $target now?" || die "Aborted before first stop."

  local v
  while read -r v; do
    [[ -z "$v" ]] && continue
    confirm "Apply upgrade stop -> $v ?" || { warn "Stopped by user before $v."; break; }
    if [[ "$GL_TYPE" == deb ]]; then deb_apply_stop "$v"; else docker_apply_stop "$v"; fi
    # refresh detected version from the live instance
    GL_VERSION="$([[ "$GL_TYPE" == deb ]] && deb_installed_version || docker_container_version "$GL_CONTAINER")"
    echo "$GL_VERSION" >"$WORK_DIR/.current_version"
    if [[ "$STEP_ONLY" == 1 ]]; then
      ok "Applied one stop (--step); current version now $GL_VERSION. Re-run to continue."
      return 0
    fi
  done <<<"$pending"

  cmd_verify
  step "Upgrade finished"
  ok "GitLab is now on $GL_VERSION (target was $target)."
}

cmd_rollback() {
  do_rollback "$WORK_DIR/backups"
}

cmd_verify() {
  detect_gitlab
  step "Post-upgrade verification"
  info "Version: $([[ "$GL_TYPE" == deb ]] && deb_installed_version || docker_container_version "$GL_CONTAINER")"
  gl_wait_ready 600 || warn "Instance not ready yet."
  info "Running gitlab-rake gitlab:check (SANITIZE=true)..."
  gl_exec gitlab-rake gitlab:check SANITIZE=true || warn "gitlab:check reported issues; review above."
  ok "Verification complete."
}

case "$COMMAND" in
  status|detect) cmd_status ;;
  preflight)     cmd_preflight ;;
  backup)        cmd_backup ;;
  upgrade)       cmd_upgrade ;;
  rollback|restore) cmd_rollback ;;
  verify)        cmd_verify ;;
  help|-h|--help) usage ;;
  *) echo "Unknown command: $COMMAND" >&2; usage; exit 1 ;;
esac
