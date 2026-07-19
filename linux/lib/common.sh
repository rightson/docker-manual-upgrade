#!/usr/bin/env bash
# =============================================================================
# common.sh - shared helpers for the GitLab offline upgrade utility
# Sourced by gitlab-offline-upgrade.sh and the other lib/*.sh files.
# =============================================================================

# ---- colours (disabled when not a tty) --------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_BLD=; C_RST=
fi

# LOG_FILE is set by the main script once the work dir is known.
LOG_FILE="${LOG_FILE:-}"

# All human-facing logging goes to STDERR so that stdout stays clean for
# functions that "return" a value via command substitution.
_log() {
  local msg="$1"
  printf '%s\n' "$msg" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s %s\n' "$(_ts)" "$msg" >>"$LOG_FILE" 2>/dev/null || true
  fi
}
# Timestamp helper (kept separate so log lines stay aligned).
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

info() { _log "${C_BLU}[*]${C_RST} $*"; }
ok()   { _log "${C_GRN}[+]${C_RST} $*"; }
warn() { _log "${C_YEL}[!]${C_RST} $*"; }
err()  { _log "${C_RED}[x]${C_RST} $*" >&2; }
step() { _log ""; _log "${C_BLD}==== $* ====${C_RST}"; }
die()  { err "$*"; exit 1; }

# ---- confirmation prompt -----------------------------------------------------
# ASSUME_YES is exported by the main script (--yes).
confirm() {
  local prompt="${1:-Proceed?}"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    info "$prompt (auto-confirmed by --yes)"
    return 0
  fi
  local reply
  read -r -p "${C_YEL}?${C_RST} $prompt [y/N] " reply || true
  [[ "$reply" =~ ^[Yy]$ ]]
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This command must be run as root (use sudo)."
  fi
}

# ---- version helpers ---------------------------------------------------------
# ver_cmp A B -> prints 0 if A==B, 1 if A>B, 2 if A<B  (numeric, dot separated)
ver_cmp() {
  local IFS=.
  local -a a=($1) b=($2)
  local i x y
  for ((i=0; i<${#a[@]} || i<${#b[@]}; i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}
    # strip any non-numeric suffix just in case (e.g. "8-ce")
    x=${x%%[!0-9]*}; y=${y%%[!0-9]*}
    x=${x:-0}; y=${y:-0}
    if ((10#$x > 10#$y)); then echo 1; return; fi
    if ((10#$x < 10#$y)); then echo 2; return; fi
  done
  echo 0
}
ver_gt() { [[ "$(ver_cmp "$1" "$2")" == 1 ]]; }
ver_ge() { local c; c=$(ver_cmp "$1" "$2"); [[ "$c" == 1 || "$c" == 0 ]]; }
ver_eq() { [[ "$(ver_cmp "$1" "$2")" == 0 ]]; }

# major.minor of a version string (e.g. 16.11.10 -> 16.11)
ver_minor() { local IFS=.; local -a a=($1); echo "${a[0]:-0}.${a[1]:-0}"; }

# ---- upgrade-path computation ------------------------------------------------
# Reads UPGRADE_PATH (space separated, ascending) and prints the subset of
# stops that are strictly greater than $current and less-or-equal to $target.
# Args: current target
compute_pending_stops() {
  local current="$1" target="$2" v
  for v in $UPGRADE_PATH; do
    if ver_gt "$v" "$current" && ver_ge "$target" "$v"; then
      printf '%s\n' "$v"
    fi
  done
}

# ---- bundle.conf loader ------------------------------------------------------
# The Windows downloader writes bundle.conf into the bundle root. It defines:
#   EDITION, CODENAME, CURRENT_VERSION, TARGET_VERSION, UPGRADE_PATH,
#   INCLUDES_DEB, INCLUDES_DOCKER
load_bundle_conf() {
  local f="$BUNDLE_DIR/bundle.conf"
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
    info "Loaded bundle manifest: $f"
  else
    warn "No bundle.conf found in $BUNDLE_DIR; falling back to config/upgrade-path.conf"
  fi

  # If UPGRADE_PATH is still unset, build it from the reference conf file.
  if [[ -z "${UPGRADE_PATH:-}" ]]; then
    local conf="$BUNDLE_DIR/config/upgrade-path.conf"
    [[ -f "$conf" ]] || conf="$SCRIPT_DIR/config/upgrade-path.conf"
    [[ -f "$conf" ]] || conf="$SCRIPT_DIR/../config/upgrade-path.conf"
    [[ -f "$conf" ]] || die "Cannot locate upgrade path (no bundle.conf and no config/upgrade-path.conf)."
    UPGRADE_PATH="$(grep -vE '^\s*(#|$)' "$conf" | tr '\n' ' ')"
  fi
  : "${EDITION:=ce}"
  : "${CODENAME:=jammy}"
  # Target defaults to the last stop in the path.
  if [[ -z "${TARGET_VERSION:-}" ]]; then
    for v in $UPGRADE_PATH; do TARGET_VERSION="$v"; done
  fi
  export EDITION CODENAME UPGRADE_PATH TARGET_VERSION CURRENT_VERSION \
         INCLUDES_DEB INCLUDES_DOCKER
}

# ---- asset path helpers ------------------------------------------------------
deb_filename()  { echo "gitlab-${EDITION}_${1}-${EDITION}.0_amd64.deb"; }
deb_path()      { echo "$BUNDLE_DIR/assets/deb/${CODENAME}/$(deb_filename "$1")"; }
image_ref()     { echo "gitlab/gitlab-${EDITION}:${1}-${EDITION}.0"; }
image_tar()     { echo "$BUNDLE_DIR/assets/docker/gitlab-${EDITION}-${1}-${EDITION}.0.tar"; }

# ---- misc --------------------------------------------------------------------
# Human readable size of a path (best effort).
hsize() { du -sh "$1" 2>/dev/null | cut -f1; }

# Poll a command until it succeeds or timeout (seconds). Args: timeout desc cmd...
wait_until() {
  local timeout="$1" desc="$2"; shift 2
  local start now
  start=$(date +%s)
  info "Waiting for: $desc (timeout ${timeout}s)"
  while true; do
    if "$@" >/dev/null 2>&1; then ok "Ready: $desc"; return 0; fi
    now=$(date +%s)
    if (( now - start > timeout )); then
      err "Timed out after ${timeout}s waiting for: $desc"
      return 1
    fi
    sleep 5
  done
}

# Ensure a minimum amount of free disk (GB) on a given path.
check_disk_gb() {
  local path="$1" need="$2" avail
  avail=$(df -BG --output=avail "$path" 2>/dev/null | tail -1 | tr -dc '0-9')
  avail=${avail:-0}
  if (( avail < need )); then
    warn "Low disk on $path: ${avail}G free, ${need}G recommended."
    return 1
  fi
  info "Disk on $path: ${avail}G free (>= ${need}G recommended)."
  return 0
}
