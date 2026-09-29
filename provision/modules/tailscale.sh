# shellcheck shell=bash
# Tailscale: install, join with a tagged one-shot key, scrub the key.

if ! command -v tailscale >/dev/null 2>&1; then
    cn="$(codename)"
    install -m 0755 -d /usr/share/keyrings
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${cn}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${cn}.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list
    # shellcheck disable=SC2034  # read by apt_update in lib.sh
    apt_updated=0
    apt_update
    apt_install tailscale
fi
systemctl enable --now tailscaled

TS_TAG="tag:rock-${ROLE}"
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname -s)}"

if tailscale_up; then
    log "tailscale already up"
elif [ -n "${TS_AUTH_KEY:-}" ]; then
    tailscale up --auth-key="$TS_AUTH_KEY" --hostname="$TS_HOSTNAME" \
        --advertise-tags="$TS_TAG" --ssh=false
    for _ in $(seq 1 30); do tailscale_up && break; sleep 1; done
else
    warn "TS_AUTH_KEY not set and tailscale is not up; run 'tailscale up --advertise-tags=$TS_TAG' manually"
fi

if tailscale_up; then
    scrub_config_key TS_AUTH_KEY
    unset TS_AUTH_KEY
fi
