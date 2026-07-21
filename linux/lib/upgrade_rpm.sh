#!/usr/bin/env bash
# =============================================================================
# upgrade_rpm.sh - apply a single upgrade "stop" to an Omnibus (rpm) install
#                  on RHEL / EL 8 (and compatible: Rocky, Alma, CentOS Stream).
# =============================================================================

rpm_apply_stop() {
  local v="$1" rpm_file; rpm_file="$(rpm_path "$v")"
  step "Upgrading (Omnibus RPM) -> $v"
  [[ -f "$rpm_file" ]] || die "Missing package for $v: $rpm_file (re-run the Windows downloader for this version)."

  info "Installing $(basename "$rpm_file") via rpm (offline)..."
  # rpm -U upgrades in place using ONLY the local file - no repo/network needed.
  if ! rpm -Uvh "$rpm_file"; then
    err "rpm upgrade failed for $v."
    err "On an offline server unmet dependencies cannot be auto-fetched."
    err "If rpm reported missing deps, download those .rpm files too and install"
    err "them alongside this package, then re-run."
    die  "Package install for $v failed."
  fi

  # Explicit reconfigure (covers /etc/gitlab/skip-auto-reconfigure) + migrations.
  info "Running gitlab-ctl reconfigure (applies schema migrations)..."
  gitlab-ctl reconfigure || die "gitlab-ctl reconfigure failed for $v."
  info "Restarting GitLab services..."
  gitlab-ctl restart >/dev/null 2>&1 || warn "gitlab-ctl restart returned non-zero (continuing)."

  gl_wait_ready 1800 || die "GitLab did not become ready after upgrading to $v."
  gl_wait_migrations   || die "Background migrations did not finish after $v; resolve before the next stop."

  local now; now="$(omnibus_installed_version)"
  ok "GitLab is now running $now"
}
