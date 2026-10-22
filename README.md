# rock

Provisioning for personal Ubuntu 24.04 hosts: cloud-init plus idempotent bash
modules. Hosts are hardened, reachable only over Tailscale, and disposable.

| Role | Host | What it gets |
|---|---|---|
| `dev` | OCI Ampere (arm64) | Node 24, gh, Claude Code, pi, srt + bubblewrap, Doppler, `/srv/catapult` |
| `preview` | Hetzner (amd64) | Docker, Caddy (public 80/443, Cloudflare DNS-01), Doppler |

Both roles get the same base: security updates, sysctl hardening, key-only SSH
for one user, Tailscale, ufw with default-deny in *and* out, and no metadata
service access for the working user.

```sh
bin/render hosts/oci.env                        # → out/oci.user-data.yaml (paste into the provider)
bin/apply hosts/oci.env dev@rock-oci            # converge an existing host
bin/apply --doppler-token hosts/oci.env dev@rock-oci
bin/apply-policy                                # validate + apply the tailnet policy
bin/sync-guide                                  # copy the design guide to catapult + conveyer
```

- Design: [`plans/00-guide.md`](plans/00-guide.md) (shared with catapult and conveyer)
- This repo's plan: [`plans/rock.md`](plans/rock.md)
- Operating it: [`docs/runbook.md`](docs/runbook.md)

## Layout

```
bin/            render, apply, apply-policy, sync-guide (run on your laptop)
cloud-init/     user-data template
hosts/          per-host, non-secret config
provision/      runs on the host: provision entrypoint, lib.sh, modules/, verify
tailscale/      tailnet policy
```

Development: `shellcheck -x provision/provision provision/verify provision/lib.sh provision/modules/*.sh bin/*`.

Before committing, enable the secret scan once per clone: `git config core.hooksPath .githooks` (needs [gitleaks](https://github.com/gitleaks/gitleaks)).
