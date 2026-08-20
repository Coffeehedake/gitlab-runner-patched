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
#   6. docker CLI + buildx   -- what our CI jobs need; previously hand-
#      + compose, Chrome,       installed and lost on every container recreate
#      python3-markdown
#   7. Vulkan loader/headers -- so fe.rhi's Vulkan backend is actually COMPILED
#      + lavapipe + the          and RUN in CI. Without these the backend is
#      validation layer          omitted at configure time and its tests skip
#                                themselves silently, which is what they had
#                                been doing on every green pipeline to date.
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
# ccache is included because the shell executor reuses the same working tree
# between jobs, so a warm cache meaningfully shortens repeat builds.
#
# This layer is intentionally separate from Layer 1 so it caches independently
# and can be removed without disturbing the GitLab-critical patches above.
#
# GCC + clang. This layer was GCC-only until r12 on the grounds that clang would
# add ~1 GB and "the GitHub Actions runner that builds it has limited free disk".
# Both halves of that were re-checked on 2026-08-12 before this change:
#
#   * the builder is not tight -- run 31596416183 reported 113 GB free on
#     /dev/root after the cleanup step (145 G total, 33 G used);
#   * Vault2 is not tight either -- 82 G free on /var/lib/docker, plus 79.5 GB
#     of reclaimable buildkit cache.
#
# The real argument was never disk, it was that the shell executor makes this
# image shared by all 45 projects while `clang-tidy` has exactly one consumer.
# That asymmetry is real and unchanged; it was overruled as not worth the
# continued back-and-forth for a one-time cost. See
# fatalexception/gitlab-ce -> docs/patched-image.md for the decision record.
#
# clang-tidy is wanted as a LINTER, not as a second compiler, so version parity
# with the GCC above is explicitly not a requirement.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ccache \
        clang \
        clang-tidy \
        cmake \
        git \
        ninja-build \
        pkg-config \
 && rm -rf /var/lib/apt/lists/* \
 && cmake --version \
 && ninja --version \
 && gcc --version | head -1 \
 && g++ --version | head -1 \
 && clang --version | head -1 \
 && clang-tidy --version | head -2

# ---- Layer 2bis: Vulkan runtime, software driver, and validation layer -------
# Added 2026-08-13 after discovering that fe.rhi's Vulkan backend had NEVER been
# exercised in CI. Every pipeline was green, and every one of them logged
#
#     -- fe.rhi: vulkan requested but no SDK found - backend omitted
#
# so the whole backend compiled to an empty translation unit and its ~20 tests
# skipped themselves honestly and silently. Green covering nothing.
#
# Three packages, each load-bearing and none redundant:
#
#   libvulkan-dev          headers + loader link target. This is what CMake's
#                          find_package(Vulkan) looks for; without it the
#                          backend is omitted at CONFIGURE time and no amount of
#                          runtime driver fixes it.
#   mesa-vulkan-drivers    lavapipe, the software rasteriser. The runner has no
#                          GPU, and this is the same adversary used in local
#                          development precisely because it answers NO to most
#                          optional features, so the "unsupported" branches are
#                          the ones that actually execute.
#   vulkan-validationlayers  the only thing in the stack that sees invalid API
#                          usage. The driver accepts a great deal of it in
#                          silence -- a device-feature bug shipped through both
#                          a code review and a green pipeline precisely because
#                          nothing was checking. fe.rhi now runs its tests with
#                          validation on and FAILS on a non-zero error count, so
#                          this package is what gives that gate teeth in CI
#                          rather than only on a developer's machine.
#
# vulkan-tools is here for triage rather than for the build: when this stops
# working, "is the ICD visible" is the first question, and `vulkaninfo` answers
# it in one line instead of a bisect.
#
#   libglvnd0 / libglx0    GLVND dispatch + libGLX.so.0.
#   libgl1 / libegl1       Added 2026-08-14. These are what make an NVIDIA GPU
#                          usable from this image, and their absence is why it
#                          previously was not.
#
# NVIDIA's Vulkan ICD is `libGLX_nvidia.so.0`, which is a GLVND *vendor* library:
# it cannot initialise without the GLVND dispatch layer (libGLdispatch.so.0,
# libGLX.so.0) being present in the image. The nvidia-container-toolkit injects
# the vendor library and writes /etc/vulkan/icd.d/nvidia_icd.json, but it does
# NOT supply GLVND -- that is the image's job, and this image had none.
#
# The failure mode is worth knowing because it names the wrong thing. With no
# dispatch layer the ICD loads fine, exports vk_icdGetInstanceProcAddr fine, and
# then returns VK_ERROR_INITIALIZATION_FAILED (-3) from
# vk_icdNegotiateLoaderICDInterfaceVersion. The Vulkan loader reports that as:
#
#     loader_scanned_icd_add: Could not get 'vkCreateInstance' via
#       'vk_icdGetInstanceProcAddr' for ICD libGLX_nvidia.so.0
#
# which reads like a corrupt or mismatched driver and sends you hunting through
# device nodes, driver capabilities and toolkit versions. It is none of those.
# `nvidia-smi` keeps working throughout, because libnvidia-ml has no GLVND
# dependency -- so GPU compute looks healthy while graphics is dead.
#
# Measured on Vault2 (RTX 3060, driver 610.57.04, toolkit 1.19.1), same host and
# same flags, one variable:
#
#     nvidia/opengl:...-glvnd-runtime  (has GLVND)  -> rc=0,  RTX 3060 enumerated
#     this image before this change    (no GLVND)   -> rc=-3, ICD dead
#     this image + these four packages              -> rc=0,  RTX 3060 enumerated
#
# See _environment/investigations/2026-08-14-gitlab-ce-vulkan-gpu.md.
#
# The assertions below are deliberately hard failures. The ICD and layer
# manifests are exactly what the Vulkan loader enumerates at runtime, so their
# presence is the meaningful check, and vulkaninfo actually exercising lavapipe
# proves the driver runs headless in a build container -- which is the property
# CI depends on. A soft `|| true` here would reproduce the original bug in a new
# place: a check that cannot fail, guarding a capability that silently vanished.
#
# FIXED 2026-08-14, same class of bug, found while adding GLVND: the last line
# used to be `vulkaninfo --summary | head -20`. A shell pipeline exits with the
# status of its LAST command, so that was `head`'s status -- always 0. If
# vulkaninfo segfaulted or found no drivers at all, the build went green anyway.
# The check that was supposed to prove the software driver runs could not fail.
# It now writes to a file, prints from the file, and greps for lavapipe, so a
# missing driver is a failed build.
#
# Note what these assertions can and cannot cover: the GitHub Actions builder has
# no GPU, so NOTHING here can prove the NVIDIA path works. `test -e` on the two
# GLVND sonames proves only that the ingredient is present. The behavioural proof
# needs the GPU host and lives post-deploy -- see the runbook reference in
# README.md. Do not read a green build as "Vulkan works on the GPU".
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libegl1 \
        libgl1 \
        libglvnd0 \
        libglx0 \
        libvulkan-dev \
        mesa-vulkan-drivers \
        vulkan-tools \
        vulkan-validationlayers \
 && rm -rf /var/lib/apt/lists/* \
 && test -f /usr/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json \
 && ls /usr/share/vulkan/icd.d/ \
 && test -e /usr/lib/x86_64-linux-gnu/libGLdispatch.so.0 \
 && test -e /usr/lib/x86_64-linux-gnu/libGLX.so.0 \
 && vulkaninfo --summary > /tmp/vkinfo.txt \
 && head -20 /tmp/vkinfo.txt \
 && grep -q llvmpipe /tmp/vkinfo.txt \
 && rm -f /tmp/vkinfo.txt

# ---- Layer 2b: dependencies our CI JOBS need ---------------------------------
# Everything here was previously hand-installed into the running container after
# each image upgrade, which meant it silently vanished the next time the
# container was recreated -- taking CI with it. That is exactly the failure this
# image exists to prevent, so it belongs in the image.
#
#   docker CLI  -- jobs build and push images through the host's docker socket
#                  (bind-mounted at /var/run/docker.sock). We install ONLY the
#                  client: the daemon is the host's, so dockerd/containerd/runc
#                  would be dead weight and confusing. Static binary rather than
#                  the apt package for exactly that reason -- the .deb drags in
#                  a daemon, systemd units and iptables we neither run nor want.
#
#   google-chrome-stable + python3-markdown
#               -- the FatalException doc-PDF builder renders through headless
#                  Chrome. NOTE: markdown lands on the SYSTEM python at
#                  /usr/bin/python3. `python3` on PATH resolves to omnibus's
#                  embedded interpreter, which cannot see system site-packages,
#                  so PDF jobs must call /usr/bin/python3 explicitly.
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/$(curl -fsSL https://download.docker.com/linux/static/stable/x86_64/ | grep -o 'docker-2[0-9.]*\.tgz' | sort -V | tail -1)" -o /tmp/docker.tgz \
 && tar -xzf /tmp/docker.tgz -C /tmp docker/docker \
 && install -m0755 /tmp/docker/docker /usr/bin/docker \
 && rm -rf /tmp/docker.tgz /tmp/docker \
 && docker --version

# ---- Layer 2c: docker CLI plugins (buildx + compose) -------------------------
# The docker CLI alone is not enough, and this is easy to miss because `docker`
# itself runs fine without them -- the failure only appears at build/deploy time:
#
#   buildx   Docker 23+ deprecated the classic builder. With DOCKER_BUILDKIT=1
#            (which joline-accounting and fallout-research both set), `docker
#            build` refuses to run without it:
#              "BuildKit is enabled but the buildx component is missing or broken"
#
#   compose  `docker compose up -d` is a plugin subcommand, not part of the CLI.
#            ci-deploy's verify step falls back to it when a container is not
#            running, so without it a recoverable deploy turns into a hard fail.
#
# Both are ordinary single-file CLI plugins: drop the binary in the plugin dir
# and the CLI discovers it. Pinned rather than "latest" so an image rebuild is
# reproducible and a rollback tag means what it says; bump the ARGs to upgrade.
# Verified against the host daemon (29.5.3) on 2026-08-11.
#
# Both curls retry. These are two unauthenticated reads from github.com release
# storage in the middle of a ~6 GB image build, and a transient failure there
# throws away the whole build: the r11 attempt (run 31630539329) died here on
# `curl` exit 52 -- "empty reply from server" -- with nothing wrong in the
# Dockerfile at all. `--retry-all-errors` is the part that matters, because
# plain `--retry` only covers transient HTTP codes and timeouts, not a dropped
# connection like 52.
ARG BUILDX_VERSION=v0.34.0
ARG COMPOSE_VERSION=v2.40.3
RUN mkdir -p /usr/local/lib/docker/cli-plugins \
 && curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
        "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
        -o /usr/local/lib/docker/cli-plugins/docker-buildx \
 && curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose \
 && chmod 0755 /usr/local/lib/docker/cli-plugins/docker-buildx \
               /usr/local/lib/docker/cli-plugins/docker-compose \
 && docker buildx version \
 && docker compose version

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3-markdown \
 && curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
        -o /tmp/chrome.deb \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/chrome.deb \
 && rm -f /tmp/chrome.deb \
 && rm -rf /var/lib/apt/lists/* \
 && google-chrome-stable --version \
 && /usr/bin/python3 -c "import markdown; print('markdown', markdown.__version__)"

# ---- Layer 2d: a real Python for CI, plus uv, ruff and pytest ----------------
# There is no usable Python in this image today, and BOTH of the ones that look
# usable fail in ways that read as a project bug rather than an image gap.
# Measured inside the running container (18.11.3-ce.0-r14) on 2026-08-20:
#
#   PATH                    /opt/gitlab/embedded/bin:/opt/gitlab/bin:/assets:
#                           /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:...
#   python3              -> /opt/gitlab/embedded/bin/python3   (3.12.12)
#     import sqlite3        ModuleNotFoundError: No module named '_sqlite3'
#   /usr/bin/python3.12     3.12.3, sqlite3 3.45.1 -- imports fine
#     python3 -m venv       fails: "ensurepip is not available"
#
# So the interpreter first on PATH cannot import sqlite3, and the interpreter
# that can cannot create a virtualenv -- Layer 1 installs `python3` without
# `python3-venv`. Neither failure names the image, so every project worked
# around it independently: arbiter-mcp's .gitlab-ci.yml downloads the uv
# installer AND a whole CPython on every job, on every pipeline, forever.
#
# It also needs 3.13 specifically (`requires-python = ">=3.13"`), which neither
# interpreter above satisfies, so "just add python3-venv" would not be enough.
#
# DELIBERATELY NOT NAMED `python3`. /usr/local/bin comes AFTER
# /opt/gitlab/embedded/bin on PATH, so a `python3` installed here would be
# silently shadowed by the broken embedded one -- exactly the trap Layer 2b
# documents for python3-markdown, which is why that comment has to tell people
# to spell out /usr/bin/python3. `ci-python` cannot be captured that way. `ruff`
# and `pytest` are safe as bare names because nothing else in the image
# provides them; if that ever changes, this layer's assertions will not notice,
# so prefer the explicit paths in a job that must not be ambiguous.
#
# Pinned, like BUILDX_VERSION and COMPOSE_VERSION above, so a rebuild is
# reproducible and a rollback tag means what it says.
#
# The assertions at the end are the point of this layer, and they are written to
# be capable of failing. The venv probe in particular is exactly what
# /usr/bin/python3.12 cannot do today: if a future base image or uv change takes
# ensurepip away again, this build stops rather than shipping an image whose
# Python looks present and cannot be used. Note they are `&&`-chained into the
# same RUN and none of them is piped, so no exit status is swallowed by a
# pipeline the way `vulkaninfo | head` was in Layer 2bis.
#
# ruff and pytest are PINNED for the same reason buildx and compose are: an
# unpinned `uv pip install ruff` makes two builds of the same commit produce
# different tools, and then a rollback tag does not mean what it says. It also
# makes a lint rule appear across all 45 projects on an unrelated rebuild.
#
# Consequence to be aware of rather than surprised by: this image's ruff is not
# necessarily the ruff a developer runs locally, and ruff changes its lint set
# between versions. A project that cares about that should keep installing its
# own from its `[dev]` extra and call the venv's copy explicitly -- these are
# for projects that do not pin, and for the lint job that would otherwise
# download ruff on every run. Bump the ARGs to move everyone at once.
ARG UV_VERSION=0.11.17
ARG RUFF_VERSION=0.16.4
ARG PYTEST_VERSION=9.1.1
ARG PYTEST_ASYNCIO_VERSION=1.4.0
ENV UV_PYTHON_INSTALL_DIR=/opt/ci/python
RUN curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
        "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
        -o /tmp/uv.tgz \
 && tar -xzf /tmp/uv.tgz -C /tmp \
 && install -m0755 /tmp/uv-x86_64-unknown-linux-gnu/uv  /usr/local/bin/uv \
 && install -m0755 /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/uvx \
 && rm -rf /tmp/uv.tgz /tmp/uv-x86_64-unknown-linux-gnu \
 && uv --version \
 && uv python install 3.13 \
 && uv venv --python 3.13 /opt/ci/tools \
 && uv pip install --python /opt/ci/tools/bin/python \
        "ruff==${RUFF_VERSION}" \
        "pytest==${PYTEST_VERSION}" \
        "pytest-asyncio==${PYTEST_ASYNCIO_VERSION}" \
 && ln -s /opt/ci/tools/bin/ruff   /usr/local/bin/ruff \
 && ln -s /opt/ci/tools/bin/pytest /usr/local/bin/pytest \
 && ln -s "$(uv python find 3.13)" /usr/local/bin/ci-python \
 && ci-python -c 'import sys, sqlite3; assert sys.version_info[:2] == (3, 13), sys.version; print("ci-python", sys.version.split()[0], "sqlite3", sqlite3.sqlite_version)' \
 && ci-python -m venv /tmp/venv-probe \
 && /tmp/venv-probe/bin/python -c 'import sqlite3; print("venv creation OK")' \
 && rm -rf /tmp/venv-probe \
 && ruff --version \
 && pytest --version

# ---- Layer 3: Node.js 20 (required by execjs gem) ----------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y nodejs \
 && ln -sf /usr/bin/node /opt/gitlab/embedded/bin/node \
 && node --version \
 && rm -rf /var/lib/apt/lists/*

# ---- Layer 4: gdk-toogle gem (omnibus 18.11.3 packaging fix) -----------------
# NOTE (2026-08): this MUST be --ignore-dependencies.
#
# gdk-toogle is only needed because it appears in GitLab 18.11.3's
# Gemfile.lock while being absent from the omnibus image -- Puma will not boot
# without the gem being *present*. Its declared runtime dependencies (rails,
# haml) are already satisfied by GitLab itself, which is a Rails application.
#
# Resolving them anyway is both unnecessary and actively harmful:
#
#   gdk-toogle -> rails -> railties -> irb -> repl_type_completor -> prism
#
# and every prism release is source-only (no precompiled gem for any platform).
# Omnibus's embedded Ruby ships no development headers, so building it fails:
#
#     mkmf.rb can't find header files for ruby at
#     /opt/gitlab/embedded/lib/ruby/include/ruby.h
#
# This is NOT a missing compiler -- build-essential does not fix it; there is
# no ruby.h to compile against. --conservative does not fix it either, because
# the resolver still walks into that dependency chain.
#
# Worse, resolving the closure means this layer is free to install a SECOND,
# newer Rails underneath a running GitLab. Installing just the gem is both the
# fix and the correct behaviour.
#
# The `gem list` assertion afterwards fails the build loudly if the gem did not
# actually land, so a silent no-op here can never reach production.
RUN /opt/gitlab/embedded/bin/gem install gdk-toogle -v 0.9.5 --no-document \
        --ignore-dependencies \
 && /opt/gitlab/embedded/bin/gem list gdk-toogle | grep -q gdk-toogle \
 && echo "gdk-toogle installed and verified"

# ---- Layer 5: gitlab-runner static binary -----------------------------------
# (Lives at the standard /usr/local/bin path. Config + state should live on a
# bind-mounted /etc/gitlab/gitlab-runner/ so they survive container recreate.)
RUN curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
        https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-linux-amd64 \
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
