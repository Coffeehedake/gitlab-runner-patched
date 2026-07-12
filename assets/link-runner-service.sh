#!/bin/bash
# gitlab-runner-patched — CMD shim.
#
# Purpose: keep the in-container gitlab-runner supervised across every container
# start. omnibus's boot (/assets/init-container -> gitlab-ctl reconfigure) rebuilds
# /opt/gitlab/service on each start and only re-creates the services it knows about
# (puma, sidekiq, ...), NOT our custom runner runit service at /opt/gitlab/sv/gitlab-runner.
# runsvdir only supervises services symlinked into /opt/gitlab/service, so without a
# re-link the runner never starts and ALL CI silently stalls at `pending` after a reboot.
#
# This shim backgrounds a linker that (re)creates that symlink once omnibus has populated
# its service dir, and keeps it in place. It is deliberately FAIL-OPEN: the linker runs in
# an isolated subshell and can never abort the boot; the script always exec's the real
# entrypoint. Worst case = pre-fix behavior (GitLab still starts).
#
# See fatalexception/gitlab-ce -> docs/ci-runner.md.

(
  while true; do
    if [ -d /opt/gitlab/sv/gitlab-runner ] \
       && { [ -e /opt/gitlab/service/sidekiq ] || [ -e /opt/gitlab/service/puma ]; }; then
      ln -sf /opt/gitlab/sv/gitlab-runner /opt/gitlab/service/gitlab-runner 2>/dev/null || true
    fi
    sleep 30
  done
) &

exec /assets/init-container "$@"
