# gitlab-runner-patched

A drop-in replacement for the upstream `gitlab/gitlab-ce` image that pre-installs the things you otherwise have to bolt onto a freshly-pulled container by hand:

| Patch | Why |
|---|---|
| **Node.js 20** + symlink to `/opt/gitlab/embedded/bin/node` | The `execjs` gem chain (used by `terser`) needs a JavaScript runtime; the upstream omnibus image doesn't bundle one |
| **`gdk-toogle 0.9.5`** | Listed in GitLab CE 18.11.3's `Gemfile.lock` but missing from the omnibus image; Puma boot fails without it |
| **`gitlab-runner`** static binary at `/usr/local/bin/gitlab-runner` | So CI works in-container with the `shell` executor — no separate runner container needed |
| **python3 + python3-pip + unzip + curl** | Required by our CI jobs |
| **C/C++ toolchain** — `build-essential`, `cmake`, `ninja-build`, `git`, `pkg-config`, `ccache` | The in-container runner uses the `shell` executor, so compiled projects' CI needs its toolchain in *this* image — there is no per-job container to install into. GCC-only by design; see below |

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

## What this image is NOT

- It does **not** modify GitLab Rails itself, change defaults, or ship any patches that affect behavior beyond installing the missing dependencies.
- It does **not** register the bundled `gitlab-runner` for you — bring your own auth token and run `gitlab-runner register --config /etc/gitlab-runner/config.toml --token glrt-...` against your own GitLab instance. **Starting/supervising it, however, IS handled** (see below).

## License

This repository (the Dockerfile, GitHub Actions workflow, and documentation) is licensed under **MIT** — see [`LICENSE`](LICENSE).

The MIT license applies only to the *files in this repo*. The Docker image produced and published to GHCR bundles many other components, each carrying its own license: GitLab CE (MIT/Apache 2.0), PostgreSQL (PostgreSQL License), Redis (terms depend on the version omnibus ships), Node.js (MIT), Ruby gems (mostly MIT or Ruby License), and the `gitlab-runner` static binary (MIT). Consumers of the published image are still bound by every one of those component licenses; nothing in this repository's MIT grant changes that.
