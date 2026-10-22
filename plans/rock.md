# rock — Plan

> Follows [`00-guide.md`](./00-guide.md). This repo provisions every host.

## Goal

One cloud-init `user-data` turns a fresh Ubuntu 24.04 VM into a hardened host in under 15 minutes. The host is reachable only over Tailscale, and its role (`dev` or `preview`) decides which modules are installed. Re-running the same scripts over SSH (`bin/apply`) converges an existing host to the same state.

rock knows nothing about catapult beyond the contract in guide §4.

## Non-goals

- Custom or golden images (D6)
- gVisor, Firecracker, microVMs (D4)
- LiteLLM, Authentik, AIDE, Falco, restic. Dropped from the old script; add them back as modules only if they're needed.
- Deploying apps to the preview host. rock only prepares it.

## Layout

```
rock/
  bin/
    render            # config + secrets → out/<host>.user-data.yaml (scripts packed inside)
    apply             # rsync to an existing host over ssh and re-run provision
    apply-policy      # validate and apply tailscale/policy.hujson via the Tailscale API
    sync-guide        # copy plans/00-guide.md into catapult and conveyer
  cloud-init/
    user-data.tmpl.yaml
  hosts/
    oci.env           # non-secret host config (role, user, swap, modules)
    hetzner.env
  provision/
    provision         # entrypoint on the host: loads config, runs modules in order
    lib.sh            # logging, write_file, apt helpers, idempotency guards
    modules/
      base.sh         # apt, packages, sysctl, limits, swap, journald, unattended-upgrades
      users.sh        # dev user, sudo, authorized_keys
      ssh.sh          # sshd hardening drop-in
      tailscale.sh    # install, join with a tagged one-shot key, scrub key from config
      firewall.sh     # ufw in/out policy, metadata block for dev user, lockout guard
      node.sh         # Node 24 LTS (NodeSource), corepack/pnpm
      tools.sh        # git, gh, jq, ripgrep, sqlite3, doppler, herdr
      harnesses.sh    # claude code (native installer), pi, srt
      sandbox.sh      # bubblewrap, socat, AppArmor userns profile for bwrap
      catapult-dirs.sh# /srv/catapult/{data,worktrees}
      docker.sh       # docker + DOCKER-USER chain
      caddy.sh        # caddy with cloudflare DNS, public 80/443
    verify            # post-provision checks; exits non-zero on failure
  tailscale/
    policy.hujson     # ACLs and tags, applied with the Tailscale API
  docs/
    runbook.md
  plans/
```

**Roles decide which modules run:**

| Role | Modules |
|---|---|
| `dev` (OCI) | base users ssh tailscale firewall node tools harnesses sandbox catapult-dirs |
| `preview` (Hetzner) | base users ssh tailscale firewall docker caddy |

`MODULES` in the host env file overrides the role's defaults (for example, add `docker` on dev for testcontainers).

## How provisioning works

1. `bin/render hosts/oci.env` reads the host config, gets the one-shot Tailscale auth key (from Doppler `rock/<host>` or `$TS_AUTH_KEY`), packs `provision/` into a gzipped tarball, and writes `out/oci.user-data.yaml`.
2. cloud-init writes the tarball and `/etc/rock/config.env` (0600), extracts to `/opt/rock`, and runs `/opt/rock/provision/provision`.
3. `provision` runs the modules in order, logs to `/var/log/rock-provision.log`, and runs `verify`.
4. After the first boot, `bin/apply dev@<host>` rsyncs `provision/` and re-runs it. The Doppler service token is sent **only** this way (over stdin), never in user-data (D14).

User-data size: the packed scripts are well under the 16–32 KB limits of both providers. `render` fails if the output exceeds 16 KB.

## Key specs

### Networking
- ufw: `deny incoming`, `deny outgoing`, then allow outgoing DNS, NTP, HTTP(S), Tailscale (41641/udp, 3478/udp), plus `EGRESS_EXTRA` (default `22/tcp` so git over SSH to tangled and GitHub works).
- `ufw allow in on tailscale0`; everything is allowed on the tailnet interface, and Tailscale ACLs decide who gets in.
- SSH is not bound to an address (D17). The firewall enforces Tailscale-only access. **Lockout guard:** if Tailscale isn't up when the firewall module runs, it opens `22/tcp` with rate limiting and marks it; `verify` fails until that is fixed.
- The `preview` role also allows `80/tcp` and `443/tcp` in, and the DOCKER-USER chain limits published container ports to 80/443.
- Metadata service: `dev` is rejected from `169.254.169.254` (a rule in `/etc/ufw/before.rules`, `ufw-before-output`, matched on uid).

### Tailscale
- Join with `--advertise-tags=tag:rock-<role>`. The auth key must be pre-authorized for that tag, single-use, and short-lived.
- After a successful join, remove `TS_AUTH_KEY` from `/etc/rock/config.env`.
- `policy.hujson`: `autogroup:member → tag:rock-dev, tag:rock-preview: *`; `tag:rock-dev → tag:rock-preview:22,443`; funnel `nodeAttrs` for `tag:rock-dev`. There is no rule letting either tag reach members' devices.

### Sandbox prerequisites
- Packages: `bubblewrap`, `socat`, `ripgrep`.
- AppArmor profile `/etc/apparmor.d/bwrap` granting `userns` to `/usr/bin/bwrap` only. The global `apparmor_restrict_unprivileged_userns` stays on.
- `srt` installed globally with npm.

### Harnesses
- Claude Code: the native installer, run as `dev` (`~/.local/bin/claude`, auto-updates).
- pi: `npm install -g @earendil-works/pi-coding-agent`.
- herdr: installed from `HERDR_INSTALL_CMD` if set. The install method isn't pinned yet.

### Multi-arch
- Everything comes from apt repos, npm, or official installers that detect the architecture. Where a download needs the architecture, use `dpkg --print-architecture`.

## Phases

### R0 — Baseline (guide phase 0)
Split `vps-hardening.sh` into modules, add roles, `render`, the cloud-init template, and `verify`. Remove the old script.
**Acceptance:** a fresh OCI VM given the rendered user-data → `ssh dev@<tailscale-name>` works, public SSH times out, `claude` and `pi` start in herdr, `verify` passes. Under 15 minutes.

### R1 — Sandbox prerequisites
**Acceptance:** `verify` shows bwrap working for `dev`, and `srt` blocking non-allowlisted egress.

### R2 — Policy as code, `apply`, Doppler handoff
**Acceptance:** from the dev host, connecting to the laptop fails; `bin/apply` run twice changes nothing the second time; `doppler run -- env` works as `dev`.

### R3 — Preview role on Hetzner
**Acceptance:** Caddy serves a test container on a preview domain over HTTPS; SSH is only reachable over Tailscale; `verify` passes.

## `verify` checks

- ufw active; incoming denied; no lockout-guard rule left
- sshd not reachable on the public IP (checked from the tailnet peer if available; locally, the ufw rule set)
- Tailscale up with the expected tag; `TS_AUTH_KEY` scrubbed
- `dev` cannot reach 169.254.169.254
- **dev role:** `node` ≥ 24, `pnpm`, `gh`, `claude`, `pi`, `srt`, `doppler`; `bwrap` works as `dev`; `/srv/catapult` exists and is owned by `dev`
- **preview role:** docker and caddy active
- unattended-upgrades enabled; swap active if configured

## Risks

- **Lockout** if Tailscale fails to join. Mitigation: the lockout guard, plus the provider console as break-glass (see runbook).
- **OCI free-tier reclamation** of idle instances. Mitigation: the host is disposable (guide principle 10).
- **Upstream installer changes** (Claude Code, NodeSource, Caddy). Mitigation: `verify` catches a missing tool; installs are isolated in single modules.
