# gitlab-runner-patched

A drop-in replacement for the upstream `gitlab/gitlab-ce` image that pre-installs the things you otherwise have to bolt onto a freshly-pulled container by hand:

| Patch | Why |
|---|---|
| **Node.js 20** + symlink to `/opt/gitlab/embedded/bin/node` | The `execjs` gem chain (used by `terser`) needs a JavaScript runtime; the upstream omnibus image doesn't bundle one |
| **`gdk-toogle 0.9.5`** | Listed in GitLab CE 18.11.3's `Gemfile.lock` but missing from the omnibus image; Puma boot fails without it |
| **`gitlab-runner`** static binary at `/usr/local/bin/gitlab-runner` | So CI works in-container with the `shell` executor — no separate runner container needed |
| **python3 + python3-pip + unzip + curl** | Required by our CI jobs |

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

## What this image is NOT

- It does **not** modify GitLab Rails itself, change defaults, or ship any patches that affect behavior beyond installing the missing dependencies.
- It does **not** register the bundled `gitlab-runner` automatically — bring your own auth token and run `gitlab-runner register --config /etc/gitlab/gitlab-runner/config.toml --token glrt-...` against your own GitLab instance, then start it (e.g. via a bind-mounted runit unit or `nohup` from a one-shot script).

## License

MIT. See `LICENSE`.
