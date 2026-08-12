# gitlab-runner-patched

A drop-in replacement for the upstream `gitlab/gitlab-ce` image that pre-installs the things you otherwise have to bolt onto a freshly-pulled container by hand:

| Patch | Why |
|---|---|
| **Node.js 20** + symlink to `/opt/gitlab/embedded/bin/node` | The `execjs` gem chain (used by `terser`) needs a JavaScript runtime; the upstream omnibus image doesn't bundle one |
| **`gdk-toogle 0.9.5`** | Listed in GitLab CE 18.11.3's `Gemfile.lock` but missing from the omnibus image; Puma boot fails without it |
| **`gitlab-runner`** static binary at `/usr/local/bin/gitlab-runner` | So CI works in-container with the `shell` executor — no separate runner container needed |
| **python3 + python3-pip + unzip + curl** | Required by our CI jobs |
| **C/C++ toolchain** — `build-essential`, `cmake`, `ninja-build`, `git`, `pkg-config`, `ccache` | The in-container runner uses the `shell` executor, so compiled projects' CI needs its toolchain in *this* image — there is no per-job container to install into. GCC-only by design; see below |
| **`docker` client** (static binary) | Jobs build and push images through the host's bind-mounted `/var/run/docker.sock`. Client only — the daemon is the host's, so `dockerd`/`containerd`/`runc` would be dead weight |
| **`docker buildx` + `docker compose` plugins** (pinned, in `/usr/local/lib/docker/cli-plugins/`) | The client alone is not enough. These are separate binaries, and `docker` runs fine without them — so the gap is invisible until a job sets `DOCKER_BUILDKIT=1` (Docker 23+ refuses to build without `buildx`) or a deploy falls back to `docker compose up`. See the gotcha below |
| **`google-chrome-stable` + `python3-markdown`** | The FatalException doc-PDF builder renders through headless Chrome. Note `markdown` lands on the **system** Python at `/usr/bin/python3` — see the gotcha below |

Built nightly (and on every push to `main`) by GitHub Actions and published to **ghcr.io/coffeehedake/gitlab-runner-patched**.

## Usage

Pin to a specific upstream GitLab version:

```bash
docker pull ghcr.io/coffeehedake/gitlab-runner-patched:18.11.3-ce.0
```

Or take the latest patched build (whatever base version we last built against):

```bash
docker pull ghcr.io/coffeehedake/gitlab-runner-patched:latest
```

### Tags, and why the immutable ones matter

Every build publishes four tags:

| Tag | Mutable? | Use |
|---|---|---|
| `:<version>` (e.g. `:18.11.3-ce.0`) | **Yes** — overwritten each build | Convenient, but see the warning |
| `:latest` | **Yes** — overwritten each build | Convenience only |
| `:<version>-r<run_number>` | No | **Pin deployments here** |
| `:<version>-<short_sha>` | No | Ties an image to an exact commit |

The moving tags are a rollback trap: if a deployment pins `:18.11.3-ce.0` and a
bad build overwrites it, re-pulling that tag fetches the *broken* image and
there is nothing to fall back to. The immutable `-r<n>` / `-<sha>` tags exist so
there is always a known-good image to point at.

**To roll back:** set the Unraid template's Repository field to the last
known-good immutable tag and re-pull. To roll forward, put the moving tag back.

It is also worth keeping a local rollback alias on the host before any upgrade:

```bash
docker tag ghcr.io/coffeehedake/gitlab-runner-patched:18.11.3-ce.0 \
           ghcr.io/coffeehedake/gitlab-runner-patched:rollback
```

### Drop-in swap example (Unraid)

In Unraid's Docker template for your existing `GitLab-CE` container, change only the **Repository** field from:

```
gitlab/gitlab-ce:latest
```

to

```
ghcr.io/coffeehedake/gitlab-runner-patched:18.11.3-ce.0
```

Keep all the bind mounts and ports identical. When you Apply, Unraid pulls the new image and recreates the container against the same `/mnt/cache/appdata/gitlab-ce/{config,data,log}` mounts — your DB, repos, and `gitlab-secrets.json` come along. Reconfigure runs automatically on first start.

### Building a different upstream version

To target a newer base GitLab tag, trigger a manual workflow run via **Actions → build-and-publish → Run workflow** and supply your desired tag (e.g. `19.0.0-ce.0`).

## The plugin gotcha — a docker client without its plugins

`buildx` and `compose` are **not** part of the docker CLI. They are standalone binaries the
client discovers in `/usr/local/lib/docker/cli-plugins/`, and `docker --version`, `ps`,
`login`, `pull` and `push` all work perfectly without them. A container missing them looks
completely healthy right up until a job needs one:

```
ERROR: BuildKit is enabled but the buildx component is missing or broken
docker: unknown command: docker compose
```

This bit for real on 2026-08-12: the client had been baked in, the plugins had not, and they
were hand-installed in the running container — so a container recreate took them with it and
every docker-dependent pipeline broke at once. Only the one project whose CI never calls
docker stayed green, which is precisely why nobody noticed.

Both are pinned via build args rather than tracking latest, so a rebuild is reproducible and
an immutable rollback tag means what it says:

```bash
docker build --build-arg BUILDX_VERSION=v0.34.0 --build-arg COMPOSE_VERSION=v2.40.3 .
```

The image smoke test asserts `docker buildx version` and `docker compose version`
individually, so a future build that loses either fails in Actions rather than after a
deploy.

**Generalises:** when you bake in a dependency, bake in whatever it dispatches to, and assert
each piece separately. A tool that is *mostly* working is very good at hiding its own gap.

## Trusted-proxies gotcha (not a Dockerfile-level fix)

Independent of this image, **don't put a bareword `'::1'` in `gitlab_rails['trusted_proxies']`** in your `gitlab.rb`. GitLab's omnibus templater renders that unquoted into `gitlab.yml`, YAML reloads it as a Ruby `Symbol`, and `IPAddr.new` raises `AddressFamilyError` during Rails boot — an error the surrounding `rescue IPAddr::InvalidAddressError` doesn't catch. The result is a 502 you can't reach.

Workarounds (any one of these is enough):

- Omit IPv6 loopback (omnibus already trusts `::1/128` via the default whitelist)
- Use the quoted CIDR form: `'::1/128'` (the `/` forces YAML to quote it as a string)

Upstream issue: <https://gitlab.com/gitlab-org/gitlab/-/work_items/585221> (open, no assignee as of 2026-05).

## CI runner auto-start (self-healing across reboots)

The bundled `gitlab-runner` runs **in-container** with the `shell` executor. Getting it to
*stay* running across restarts is the tricky part, and this image handles it:

- Ships a **runit service** at `/opt/gitlab/sv/gitlab-runner` (`run` + `log/run`).
- Ships a **fail-open CMD shim** (`/usr/local/bin/link-runner-service.sh`, the image's `CMD`)
  that backgrounds a linker and then `exec`s the stock `/assets/init-container`.

Why the shim is needed: omnibus rebuilds `/opt/gitlab/service/` on every boot (via
`gitlab-ctl reconfigure`) and only recreates the services it knows about (`puma`, `sidekiq`,
…), **not** the custom runner. `runsvdir` only supervises what's symlinked there, so without a
re-link the runner never starts and **all CI silently stalls at `pending`** after a reboot.
The shim keeps `/opt/gitlab/service/gitlab-runner` symlinked in, so `runsvdir` supervises it.
It's fail-open — the linker runs in an isolated subshell and the shim always `exec`s the real
entrypoint, so it can never prevent GitLab from booting.

You still **register** your runner once (`gitlab-runner register …`). Put `config.toml` on a
**bind-mounted `/etc/gitlab-runner/`** so the registration survives image redeploys.

> **If you set the container's command** (Unraid "Post Arguments", compose `command:`, or
> `docker run … <cmd>`), you override the image `CMD` and bypass the shim — leave the command
> unset so `/usr/local/bin/link-runner-service.sh` runs.

Background + full ops runbook: `fatalexception/gitlab-ce` → `docs/ci-runner.md` (on the
self-hosted GitLab).

## C/C++ toolchain for CI

Because the runner uses the `shell` executor, a job that compiles runs directly
inside this container — there is no per-job image to `apt install` into. Any
project whose CI runs `cmake` needs that toolchain baked in here, or the job
fails on `cmake: not found`.

Included: `build-essential` (gcc/g++/make), `cmake`, `ninja-build`, `git`,
`pkg-config`, `ccache`.

**Deliberately GCC-only.** `clang` and `clang-tidy` would add roughly another
gigabyte to an image already around 3.3 GB, and the GitHub Actions runner that
builds it has limited free disk. GCC covers compilation, `ctest`, and the
ASan/UBSan sanitizer jobs (`libasan`/`libubsan` ship with g++). Add clang only
if a project genuinely needs `clang-tidy` in CI — and expect to trim elsewhere.

`ccache` is included because the shell executor reuses the same working tree
between jobs, so a warm cache meaningfully shortens repeat builds.

### Concurrency

`concurrent` in `/etc/gitlab-runner/config.toml` governs how many jobs run at
once **across the whole instance**. With `concurrent = 1`, a long compile
blocks every other project's CI. Raise it (2 is a reasonable start on a 12-core
host) and keep per-job build parallelism modest — e.g. `CMAKE_BUILD_PARALLEL_LEVEL: 4`
— so two concurrent jobs don't oversubscribe the CPU or starve GitLab itself.
That file is bind-mounted, so the setting survives container recreate.

## Why this list keeps growing

Everything here has the same origin story: it was hand-installed into a running container to
make something work, and then silently vanished the next time that container was recreated —
taking CI with it, usually noticed hours later on a project nobody was watching.

On 2026-08-11 a container recreate discarded a writable layer that had accumulated since May,
including the `docker` client, Chrome and `python3-markdown`. One project's image build died
on `docker: command not found`; another's PDF job would have died the same way. One of those
projects' CI files even carried a comment listing exactly which packages to reinstall "after
a GitLab-CE image upgrade" — the knowledge existed, it was just written as a manual step
instead of a Dockerfile layer.

So the rule for this image: **if a CI job needs a tool, it belongs in the image.** When you
catch yourself running `docker exec <container> apt install ...` to make a pipeline pass, do
it to unblock, then add the layer the same day.

## Build gotcha — the `gdk-toogle` layer needs `--ignore-dependencies`

Without it the build fails, and it failed unnoticed for roughly two months — which meant the
deployed image went stale and a runner fix that had been committed in July never actually
shipped.

Ruby 3.3 ships `prism` as a default gem, and omnibus's embedded Ruby ships **no development
headers**. A plain `gem install gdk-toogle` resolves the full closure —
`gdk-toogle → rails → railties → irb → repl_type_completor → prism` — and every `prism`
release is source-only. Building its native extension dies with:

```
mkmf.rb can't find header files for ruby at /opt/gitlab/embedded/lib/ruby/include/ruby.h
```

This is **not** a missing compiler. Adding `build-essential` does not help — there is no
`ruby.h` to compile against. `--conservative` does not help either; the resolver still walks
into that chain.

The gem's runtime dependencies (`rails`, `haml`) are already satisfied by GitLab, which *is*
a Rails app — Puma only needs the gem to **exist**. Resolving the closure was never
necessary, and it allowed this layer to install a second, newer Rails underneath a running
GitLab. `--ignore-dependencies` installs exactly the missing gem and nothing else.

## The `python3` trap

`python3` on `PATH` resolves to omnibus's embedded interpreter
(`/opt/gitlab/embedded/bin/python3`), which **cannot see system site-packages**.
`python3-markdown` installs to the system Python at `/usr/bin/python3`.

A job running `python3 build-pdfs.py` therefore fails with `ModuleNotFoundError: markdown`
even though the package installed correctly. Call `/usr/bin/python3` explicitly.

## Pre-deploy smoke test

The workflow runs the freshly built image and asserts cmake, ninja, gcc, g++, python3, node,
`gitlab-runner`, `docker`, `google-chrome-stable`, `markdown` and the runit shim are all
present. A layer that quietly stops installing something fails the build here rather than
after the image has been deployed and GitLab taken down.

## What this image is NOT

- It does **not** modify GitLab Rails itself, change defaults, or ship any patches that affect behavior beyond installing the missing dependencies.
- It does **not** register the bundled `gitlab-runner` for you — bring your own auth token and run `gitlab-runner register --config /etc/gitlab-runner/config.toml --token glrt-...` against your own GitLab instance. **Starting/supervising it, however, IS handled** (see below).

## License

This repository (the Dockerfile, GitHub Actions workflow, and documentation) is licensed under **MIT** — see [`LICENSE`](LICENSE).

The MIT license applies only to the *files in this repo*. The Docker image produced and published to GHCR bundles many other components, each carrying its own license: GitLab CE (MIT/Apache 2.0), PostgreSQL (PostgreSQL License), Redis (terms depend on the version omnibus ships), Node.js (MIT), Ruby gems (mostly MIT or Ruby License), and the `gitlab-runner` static binary (MIT). Consumers of the published image are still bound by every one of those component licenses; nothing in this repository's MIT grant changes that.
