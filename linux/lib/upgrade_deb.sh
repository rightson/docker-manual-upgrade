#!/usr/bin/env bash
# =============================================================================
# upgrade_deb.sh - apply a single upgrade "stop" to an Omnibus (deb) install.
# =============================================================================

deb_apply_stop() {
  local v="$1" deb; deb="$(deb_path "$v")"
  step "Upgrading (Omnibus package) -> $v"
  [[ -f "$deb" ]] || die "Missing package for $v: $deb (re-run the Windows downloader for this version)."

  info "Installing $(basename "$deb") via dpkg (offline)..."
  # --force-confold/--force-confdef: never prompt about config files, keep ours.
  if ! DEBIAN_FRONTEND=noninteractive dpkg -i --force-confold --force-confdef "$deb"; then
    err "dpkg failed installing $v."
    err "On an offline server unmet dependencies cannot be auto-fetched."
    err "If dpkg reported missing deps, download those .deb files too and place"
    err "them beside this package, then re-run."
    die  "Package install for $v failed."
  fi

  # The package normally auto-reconfigures, but run it explicitly to cover
  # /etc/gitlab/skip-auto-reconfigure and to apply schema migrations now.
  info "Running gitlab-ctl reconfigure (applies schema migrations)..."
  gitlab-ctl reconfigure || die "gitlab-ctl reconfigure failed for $v."
  info "Restarting GitLab services..."
  gitlab-ctl restart >/dev/null 2>&1 || warn "gitlab-ctl restart returned non-zero (continuing)."

  gl_wait_ready 1800 || die "GitLab did not become ready after upgrading to $v."
  gl_wait_migrations   || die "Background migrations did not finish after $v; resolve before the next stop."

  local now; now="$(deb_installed_version)"
  ok "GitLab is now running $now"
}
