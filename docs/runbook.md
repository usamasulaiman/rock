# rock runbook

## Provision a new host

1. **Tailscale auth key.** In the admin console (or API) create a key that is
   *pre-authorized*, *single-use*, expires in ≤ 1 hour, and is tagged
   `tag:rock-dev` (OCI) or `tag:rock-preview` (Hetzner). Store it in Doppler as
   `TS_AUTH_KEY` in project `rock`, config `oci` / `hetzner`, or export it.
2. **Render:** `bin/render hosts/oci.env` → `out/oci.user-data.yaml`.
3. **Create the VM** (Ubuntu 24.04) and paste the file as cloud-init user-data
   (OCI: *Advanced options → Management → cloud-init script*; Hetzner: *Cloud config*).
4. **Provider firewall** (second layer): OCI security list / Hetzner firewall
   with no inbound rules on dev hosts; 80/443 only on preview hosts.
5. Wait ~10 minutes, then `ssh dev@rock-oci` over Tailscale.
   Logs: `/var/log/rock-provision.log`. Re-check any time: `sudo /opt/rock/provision/verify`.
6. **Doppler token:** create a *service token* scoped to the host's config
   (dev secrets only, never prod), then `bin/apply --doppler-token hosts/oci.env dev@rock-oci`.
   The token lands in `/etc/rock/doppler.env` (root:dev 0640). Interactive
   agents running as `dev` can read it; sandboxed catapult jobs cannot.

## Change a host

Edit modules or `hosts/*.env`, then `bin/apply hosts/oci.env dev@rock-oci [module...]`.
Running it twice must be a no-op the second time.

## Tailnet policy

`tailscale/policy.hujson` is the source of truth. Apply with the Tailscale API
(`POST /api/v2/tailnet/-/acl`) or the `tailscale/gitops-acl-action`.

## Break-glass

If Tailscale is down, SSH is unreachable by design.

- OCI: *Instance → Console connection* (serial console). Hetzner: *Console* in the Cloud UI.
- The `dev` user has no password. From the provider console, log in as root
  through the provider's rescue flow, or set one temporarily:
  `passwd dev` (remove it afterwards with `passwd -d dev`).
- If provision ran without Tailscale, the firewall module opened `22/tcp`
  publicly with rate limiting (`/var/lib/rock/lockout-guard` exists). Fix
  Tailscale, then `sudo /opt/rock/provision/provision firewall` to close it.

## Rebuild instead of repair

Hosts are disposable (guide principle 10). catapult state is restored from
Litestream; code lives in git remotes; agent config comes from conveyer.
