#!/usr/bin/env bash
# =============================================================================
# detect.sh - discover how GitLab is installed on this host and its version.
# Exposes: GL_TYPE (deb|docker), GL_VERSION, GL_EDITION, GL_CONTAINER (docker),
#          and docker run-spec helpers.
# =============================================================================

# --- Omnibus (deb) ------------------------------------------------------------
deb_installed_version() {
  # Prefer the VERSION file (fast, exact app version); fall back to dpkg.
  local vf pkg
  for vf in /opt/gitlab/embedded/service/gitlab-rails/VERSION; do
    [[ -r "$vf" ]] && { tr -d '[:space:]' <"$vf"; return 0; }
  done
  for pkg in gitlab-ce gitlab-ee; do
    if dpkg-query -W -f='${Version}' "$pkg" >/dev/null 2>&1; then
      dpkg-query -W -f='${Version}' "$pkg" | sed -E 's/-(ce|ee)\..*$//'
      return 0
    fi
  done
  return 1
}

deb_installed_edition() {
  if dpkg-query -W gitlab-ee >/dev/null 2>&1; then echo ee
  elif dpkg-query -W gitlab-ce >/dev/null 2>&1; then echo ce
  else echo "${EDITION:-ce}"; fi
}

# --- Docker -------------------------------------------------------------------
# Is a working docker daemon reachable?
docker_available() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# Find the GitLab container. Honours GL_CONTAINER if the caller set it.
docker_find_container() {
  docker_available || return 1
  if [[ -n "${GL_CONTAINER:-}" ]]; then
    docker inspect "$GL_CONTAINER" >/dev/null 2>&1 && { echo "$GL_CONTAINER"; return 0; }
    return 1
  fi
  # Any container (running or not) whose image is gitlab/gitlab-(ce|ee)
  local id
  id=$(docker ps -a --filter "ancestor=gitlab/gitlab-ce" --format '{{.Names}}' 2>/dev/null | head -1)
  [[ -z "$id" ]] && id=$(docker ps -a --filter "ancestor=gitlab/gitlab-ee" --format '{{.Names}}' 2>/dev/null | head -1)
  # Fallback: match by image name substring across all containers
  if [[ -z "$id" ]]; then
    id=$(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk -F'\t' '$2 ~ /gitlab\/gitlab-(ce|ee)/ {print $1; exit}')
  fi
  [[ -n "$id" ]] && { echo "$id"; return 0; }
  return 1
}

docker_container_image() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null; }

docker_container_version() {
  local c="$1" img ver
  img=$(docker_container_image "$c")
  # Try tag first: gitlab/gitlab-ce:16.1.8-ce.0 -> 16.1.8
  ver=$(sed -nE 's#.*:([0-9]+\.[0-9]+\.[0-9]+)-(ce|ee)\.[0-9]+$#\1#p' <<<"$img")
  if [[ -z "$ver" ]]; then
    # Ask the container directly (works even for :latest tags)
    ver=$(docker exec "$c" cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null | tr -d '[:space:]')
  fi
  echo "$ver"
}

docker_container_edition() {
  local img; img=$(docker_container_image "$1")
  if   [[ "$img" == *gitlab-ee* ]]; then echo ee
  elif [[ "$img" == *gitlab-ce* ]]; then echo ce
  else echo "${EDITION:-ce}"; fi
}

# Is this container managed by docker compose? (prints project/file/service)
docker_is_compose() {
  local c="$1"
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null \
    | grep -q .
}
docker_compose_file() {
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$1" 2>/dev/null
}
docker_compose_workdir() {
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$1" 2>/dev/null
}
docker_compose_service() {
  docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$1" 2>/dev/null
}

# Host path backing the container's /etc/gitlab (for secrets backup), best effort.
docker_mount_source() {
  # Args: container destination
  docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Source}}{{end}}{{end}}" "$1" 2>/dev/null
}

# --- top-level detection ------------------------------------------------------
# Sets GL_TYPE, GL_VERSION, GL_EDITION, GL_CONTAINER (if docker).
# Honours an explicit FORCE_TYPE (deb|docker|auto).
detect_gitlab() {
  local want="${FORCE_TYPE:-auto}"

  if [[ "$want" == "deb" || "$want" == "auto" ]]; then
    if command -v gitlab-ctl >/dev/null 2>&1 && deb_installed_version >/dev/null 2>&1; then
      GL_TYPE=deb
      GL_VERSION=$(deb_installed_version)
      GL_EDITION=$(deb_installed_edition)
      return 0
    fi
    [[ "$want" == "deb" ]] && die "Requested --type deb but no Omnibus GitLab package is installed here."
  fi

  if [[ "$want" == "docker" || "$want" == "auto" ]]; then
    if [[ "$want" == docker ]] && ! docker_available; then
      die "Requested --type docker but the docker daemon is not reachable."
    fi
    if docker_available; then
      local c
      if c=$(docker_find_container); then
        GL_TYPE=docker
        GL_CONTAINER="$c"
        GL_VERSION=$(docker_container_version "$c")
        GL_EDITION=$(docker_container_edition "$c")
        return 0
      fi
    fi
    [[ "$want" == "docker" ]] && die "Requested --type docker but no gitlab/gitlab-* container was found."
  fi

  die "Could not detect a GitLab installation (neither Omnibus package nor Docker container)."
}

# --- unified execution --------------------------------------------------------
# Run a gitlab command against the active install (host binary or docker exec).
gl_exec() {
  if [[ "$GL_TYPE" == docker ]]; then
    docker exec "$GL_CONTAINER" "$@"
  else
    "$@"
  fi
}
# Run a shell snippet (login shell so /opt/gitlab/bin is on PATH inside images).
gl_sh() {
  if [[ "$GL_TYPE" == docker ]]; then
    docker exec "$GL_CONTAINER" bash -lc "$1"
  else
    bash -lc "$1"
  fi
}
# Run a single SQL statement returning one scalar (integer) via gitlab-psql.
gl_psql_scalar() {
  gl_sh "gitlab-psql -tAc \"$1\"" 2>/dev/null | tr -dc '0-9-'
}

# Readiness probe: GitLab can run a trivial rails command against the DB.
_gl_ready_check() { gl_sh 'gitlab-rails runner -e production "exit 0"'; }
# Wait until GitLab is accepting DB work again (readiness after reconfigure).
gl_wait_ready() {
  local timeout="${1:-1800}"
  wait_until "$timeout" "GitLab services to become ready" _gl_ready_check
}

# --- background migration gate ------------------------------------------------
# GitLab runs "batched background migrations" asynchronously after an upgrade.
# They MUST finish before moving to the next required stop, or data can be lost.
# Status enum: 3=finished, 6=finalized (both "done"); 4=failed; others pending.
_gl_migrations_pending() {
  gl_psql_scalar "SELECT COUNT(*) FROM batched_background_migrations WHERE status NOT IN (3,6);"
}
_gl_migrations_failed() {
  gl_psql_scalar "SELECT COUNT(*) FROM batched_background_migrations WHERE status = 4;"
}
gl_wait_migrations() {
  local timeout="${1:-14400}" start now pend fail
  start=$(date +%s)
  info "Waiting for batched background migrations to finish (timeout ${timeout}s)."
  while true; do
    fail=$(_gl_migrations_failed); fail=${fail:-0}
    if [[ "${fail:-0}" -gt 0 ]] 2>/dev/null; then
      err "$fail batched background migration(s) are in FAILED state."
      err "Inspect them, then re-run once resolved:"
      err "  gitlab-psql -c \"SELECT job_class_name, table_name, status FROM batched_background_migrations WHERE status = 4;\""
      return 1
    fi
    pend=$(_gl_migrations_pending); pend=${pend:-0}
    if [[ "${pend:-0}" == 0 ]]; then ok "All batched background migrations complete."; return 0; fi
    now=$(date +%s)
    if (( now - start > timeout )); then
      err "Timed out with $pend background migration(s) still pending."
      err "Check progress in the Admin area > Monitoring > Background migrations, then re-run."
      return 1
    fi
    info "  $pend background migration(s) still running; re-checking in 30s..."
    sleep 30
  done
}

print_detection() {
  step "Detected GitLab installation"
  info "Type       : $GL_TYPE"
  info "Edition    : $GL_EDITION"
  info "Version    : ${GL_VERSION:-unknown}"
  if [[ "$GL_TYPE" == docker ]]; then
    info "Container  : $GL_CONTAINER (image $(docker_container_image "$GL_CONTAINER"))"
  fi
  return 0
}
