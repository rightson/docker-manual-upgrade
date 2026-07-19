#!/usr/bin/env bash
# =============================================================================
# upgrade_docker.sh - apply a single upgrade "stop" to a Docker install.
#
# GitLab data lives in the container's volumes (/etc/gitlab, /var/opt/gitlab,
# /var/log/gitlab). Upgrading = run a NEW image against the SAME volumes; GitLab
# reconfigures and migrates on start. Two strategies are supported:
#   * compose-managed containers -> bump the image tag and `docker compose up -d`
#   * plain `docker run` containers -> recreate from `docker inspect`
# =============================================================================

# Load an image tar into the local docker if the image is not already present.
docker_ensure_image() {
  local v="$1" ref tar; ref="$(image_ref "$v")"; tar="$(image_tar "$v")"
  if docker image inspect "$ref" >/dev/null 2>&1; then
    info "Image already loaded: $ref"; return 0
  fi
  [[ -f "$tar" ]] || die "Missing image archive for $v: $tar (re-run the Windows downloader)."
  info "Loading image $ref from $(basename "$tar") (this can take a minute)..."
  docker load -i "$tar" || die "docker load failed for $tar."
  docker image inspect "$ref" >/dev/null 2>&1 || die "Image $ref not present after load."
}

# Reconstruct docker run arguments (one token per line) from an existing container.
docker_build_run_args() {
  local c="$1"
  # --hostname (skip if it's just the auto-assigned short container id)
  local hn; hn="$(docker inspect -f '{{.Config.Hostname}}' "$c" 2>/dev/null)"
  if [[ -n "$hn" && ! "$hn" =~ ^[0-9a-f]{12}$ ]]; then
    printf -- '--hostname\n%s\n' "$hn"
  fi
  # --restart
  local rp; rp="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)"
  if [[ -n "$rp" && "$rp" != "no" && "$rp" != "<no value>" ]]; then
    printf -- '--restart\n%s\n' "$rp"
  fi
  # --shm-size
  local shm; shm="$(docker inspect -f '{{.HostConfig.ShmSize}}' "$c" 2>/dev/null)"
  if [[ "$shm" =~ ^[0-9]+$ && "$shm" -gt 0 ]]; then
    printf -- '--shm-size\n%s\n' "$shm"
  fi
  # -v (bind mounts and named/anonymous volumes; preserves data across recreate)
  local mtype src name dest rw vol
  while IFS='|' read -r mtype src name dest rw; do
    [[ -z "$dest" ]] && continue
    if   [[ "$mtype" == bind   ]]; then vol="$src:$dest"
    elif [[ "$mtype" == volume ]]; then vol="${name}:$dest"
    else continue; fi
    [[ "$rw" == "true" ]] || vol="$vol:ro"
    printf -- '-v\n%s\n' "$vol"
  done < <(docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Name}}|{{.Destination}}|{{.RW}}{{"\n"}}{{end}}' "$c")
  # -p (published ports)
  local hostip hostport cport spec
  while IFS='|' read -r hostip hostport cport; do
    [[ -z "$cport" ]] && continue
    spec="${hostport}:${cport%%/*}"
    [[ -n "$hostip" && "$hostip" != "0.0.0.0" ]] && spec="$hostip:$spec"
    [[ "$cport" == */udp ]] && spec="$spec/udp"
    printf -- '-p\n%s\n' "$spec"
  done < <(docker inspect -f '{{range $p,$conf := .HostConfig.PortBindings}}{{range $conf}}{{.HostIp}}|{{.HostPort}}|{{$p}}{{"\n"}}{{end}}{{end}}' "$c")
  # -e (only safe/user-relevant env; other settings should live in gitlab.rb)
  local e
  while IFS= read -r e; do
    case "$e" in
      GITLAB_OMNIBUS_CONFIG=*|TZ=*) printf -- '-e\n%s\n' "$e" ;;
    esac
  done < <(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c")
}

# Recreate container $oldc under $name using $newimg, preserving all config.
docker_recreate() {
  local oldc="$1" newimg="$2" name="$3"
  local -a runargs=()
  mapfile -t runargs < <(docker_build_run_args "$oldc")

  info "Stopping container '$oldc'..."
  docker stop "$oldc" >/dev/null 2>&1 || warn "docker stop returned non-zero."
  # Remove WITHOUT -v so named/bind/anonymous volumes (and their data) survive.
  docker rm "$oldc" >/dev/null 2>&1 || docker rm -f "$oldc" >/dev/null 2>&1 || true

  # Record the exact command for transparency / manual rollback.
  { printf 'docker run --detach --name %q' "$name"
    printf ' %q' "${runargs[@]}"
    printf ' %q\n' "$newimg"; } | tee "$WORK_DIR/last-docker-run.txt"

  if [[ "${ASSUME_YES:-0}" != "1" ]]; then
    confirm "Run the docker command above to start the new container?" || die "Aborted by user."
  fi

  info "Starting new container '$name' with $newimg..."
  docker run --detach --name "$name" "${runargs[@]}" "$newimg" >/dev/null \
    || die "docker run failed for $newimg."
  GL_CONTAINER="$name"
}

# Compose strategy: bump the image tag in the compose file and `up -d`.
docker_compose_apply() {
  local newimg="$1" c="$GL_CONTAINER" cf svc wd
  cf="$(docker_compose_file "$c")"; cf="${cf%%,*}"
  svc="$(docker_compose_service "$c")"
  wd="$(docker_compose_workdir "$c")"
  [[ -f "$cf" ]] || { warn "Compose file '$cf' not found; will recreate instead."; return 1; }

  cp -a "$cf" "$WORK_DIR/$(basename "$cf").bak.$(date +%s)"
  info "Setting gitlab image to $newimg in $cf (service '$svc')"
  sed -i -E "s#gitlab/gitlab-(ce|ee):[^\"'[:space:]]+#${newimg}#g" "$cf"
  if ! grep -q "$newimg" "$cf"; then
    warn "Could not update the image line automatically; will recreate instead."
    return 1
  fi
  ( cd "$wd" && docker compose -f "$cf" up -d "$svc" ) || die "docker compose up -d failed."
  # container name is stable under compose; GL_CONTAINER stays valid
  return 0
}

docker_apply_stop() {
  local v="$1" newimg; newimg="$(image_ref "$v")"
  step "Upgrading (Docker) -> $v"
  docker_ensure_image "$v"

  if docker_is_compose "$GL_CONTAINER"; then
    info "Container '$GL_CONTAINER' is docker-compose managed."
    docker_compose_apply "$newimg" || docker_recreate "$GL_CONTAINER" "$newimg" "$GL_CONTAINER"
  else
    docker_recreate "$GL_CONTAINER" "$newimg" "$GL_CONTAINER"
  fi

  gl_wait_ready 2400 || die "Container did not become ready after upgrading to $v."
  gl_wait_migrations   || die "Background migrations did not finish after $v; resolve before the next stop."
  ok "Container now running $(docker_container_version "$GL_CONTAINER")"
}
