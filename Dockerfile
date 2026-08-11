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
#   5. C/C++ toolchain       -- cmake/gcc/ninja for compiled projects' CI
#                                (installed EARLY, before the gem layer)
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

# ---- Layer 2: C/C++ toolchain for compiled projects' CI ---------------------
# The in-container runner uses the `shell` executor, so a CI job that compiles
# needs its toolchain present in THIS image -- there is no per-job container to
# install into. Without this, jobs fail on `cmake: not found`.
#
# Deliberately GCC-only. clang/clang-tidy would add roughly another gigabyte to
# an image that is already ~3.3 GB, and the GitHub Actions runner that builds it
# has limited free disk. GCC covers compilation, ctest, and the ASan/UBSan
# sanitizer jobs (libasan/libubsan ship with g++). Add clang later only if a
# project genuinely needs clang-tidy in CI.
#
# ccache is included because the shell executor reuses the same working tree
# between jobs, so a warm cache meaningfully shortens repeat builds.
#
# This layer is intentionally separate from Layer 1 so it caches independently
# and can be removed without disturbing the GitLab-critical patches above.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ccache \
        cmake \
        git \
        ninja-build \
        pkg-config \
 && rm -rf /var/lib/apt/lists/* \
 && cmake --version \
 && ninja --version \
 && gcc --version | head -1 \
 && g++ --version | head -1

# ---- Layer 3: Node.js 20 (required by execjs gem) ----------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y nodejs \
 && ln -sf /usr/bin/node /opt/gitlab/embedded/bin/node \
 && node --version \
 && rm -rf /var/lib/apt/lists/*

# ---- Layer 4: gdk-toogle gem (omnibus 18.11.3 packaging fix) -----------------
# NOTE (2026-08): this MUST be --conservative --minimal-deps.
#
# Ruby 3.3 ships `prism` as a DEFAULT gem, and omnibus's embedded Ruby ships no
# development headers. A plain `gem install` resolves dependencies to their
# newest versions, decides to upgrade prism (1.9.0 has no precompiled gem for
# any platform -- every release is source-only), and dies with:
#
#     mkmf.rb can't find header files for ruby at
#     /opt/gitlab/embedded/lib/ruby/include/ruby.h
#
# It is not a missing compiler -- adding build-essential does not fix it. The
# embedded Ruby simply has no ruby.h to compile an extension against.
#
# --conservative keeps any already-installed gem that satisfies the requirement
# (the bundled prism, and GitLab's own rails tree) instead of upgrading it, and
# --minimal-deps installs only genuinely missing dependencies. Together they
# stop the resolver reaching for a source-only prism, and as a bonus stop this
# layer quietly pulling a newer Rails underneath GitLab.
RUN /opt/gitlab/embedded/bin/gem install gdk-toogle -v 0.9.5 --no-document \
        --conservative --minimal-deps \
 && /opt/gitlab/embedded/bin/gem list gdk-toogle | grep gdk-toogle

# ---- Layer 5: gitlab-runner static binary -----------------------------------
# (Lives at the standard /usr/local/bin path. Config + state should live on a
# bind-mounted /etc/gitlab/gitlab-runner/ so they survive container recreate.)
RUN curl -fsSL https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-linux-amd64 \
        -o /usr/local/bin/gitlab-runner \
 && chmod +x /usr/local/bin/gitlab-runner \
 && /usr/local/bin/gitlab-runner --version

# ---- Layer 6: supervise the in-container runner + self-heal its runit symlink ---
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
