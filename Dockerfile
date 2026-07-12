# syntax=docker/dockerfile:1.7
#
# gitlab-runner-patched
# =====================
# A drop-in replacement for `gitlab/gitlab-ce` that bakes in everything we
# had to install manually after `gitlab-ctl reconfigure` on 18.11.3:
#
#   1. Node.js 20            -- required by the execjs / terser gem path
#   2. gdk-toogle 0.9.5      -- present in Gemfile.lock but missing from
#                                the upstream omnibus 18.11.3 image
#   3. python3 + unzip + curl-- needed by our CI jobs
#   4. gitlab-runner binary  -- so we don't need a separate runner container
#
# Trusted-proxies note (NOT a Dockerfile change): GitLab CE 18.11.3 (and
# master at the time of writing) crashes Rails boot if `gitlab.rb` has a
# bareword IPv6 literal (e.g. `'::1'`) in `gitlab_rails['trusted_proxies']`
# because the omnibus templater renders it unquoted into gitlab.yml,
# YAML re-loads it as a Ruby Symbol, and IPAddr.new(symbol) raises
# AddressFamilyError which the initializer's rescue doesn't catch.
# Workaround: either omit IPv6 loopback or use the quoted CIDR form
# `'::1/128'`. See upstream issue
# https://gitlab.com/gitlab-org/gitlab/-/work_items/585221
#
ARG GITLAB_VERSION=18.11.3-ce.0
FROM gitlab/gitlab-ce:${GITLAB_VERSION}

LABEL org.opencontainers.image.source="https://github.com/coffeehedake/gitlab-runner-patched"
LABEL org.opencontainers.image.description="GitLab CE with execjs/gem/runner/CI patches baked in"
LABEL org.opencontainers.image.licenses="MIT"

# ---- Layer 1: system packages used by CI jobs and the runner -----------------
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        python3 \
        python3-pip \
        unzip \
 && rm -rf /var/lib/apt/lists/*

# ---- Layer 2: Node.js 20 (required by execjs gem) ----------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y nodejs \
 && ln -sf /usr/bin/node /opt/gitlab/embedded/bin/node \
 && node --version \
 && rm -rf /var/lib/apt/lists/*

# ---- Layer 3: gdk-toogle gem (omnibus 18.11.3 packaging fix) -----------------
RUN /opt/gitlab/embedded/bin/gem install gdk-toogle -v 0.9.5 --no-document

# ---- Layer 4: gitlab-runner static binary -----------------------------------
# (Lives at the standard /usr/local/bin path. Config + state should live on a
# bind-mounted /etc/gitlab/gitlab-runner/ so they survive container recreate.)
RUN curl -fsSL https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-linux-amd64 \
        -o /usr/local/bin/gitlab-runner \
 && chmod +x /usr/local/bin/gitlab-runner \
 && /usr/local/bin/gitlab-runner --version

# ---- Layer 5: supervise the in-container runner + self-heal its runit symlink ---
# The runner binary alone isn't enough. omnibus rebuilds /opt/gitlab/service on every
# boot (via `gitlab-ctl reconfigure` inside /assets/init-container) and only recreates
# the services it knows about (puma, sidekiq, ...), NOT our custom runner. runsvdir only
# supervises services symlinked into /opt/gitlab/service, so without a re-link the runner
# never starts and ALL CI silently stalls at `pending` after a reboot.
#
# Fix: ship the runit service, plus a FAIL-OPEN CMD shim that re-links it into
# /opt/gitlab/service after reconfigure and keeps it linked. The shim always exec's the
# real entrypoint, so it can never stop GitLab from booting. Runner config (registered
# runners + tokens) lives on the bind-mounted /etc/gitlab-runner, so it survives redeploys.
# See fatalexception/gitlab-ce -> docs/ci-runner.md.
COPY runit/gitlab-runner/ /opt/gitlab/sv/gitlab-runner/
COPY assets/link-runner-service.sh /usr/local/bin/link-runner-service.sh
RUN chmod +x /opt/gitlab/sv/gitlab-runner/run \
             /opt/gitlab/sv/gitlab-runner/log/run \
             /usr/local/bin/link-runner-service.sh

# Base image CMD is ["/assets/init-container"]; wrap it so the linker runs alongside boot.
# NOTE: do NOT override the container command in the Unraid template, or this shim is bypassed.
CMD ["/usr/local/bin/link-runner-service.sh"]
