# shellcheck shell=bash
# ufw policy. Inbound: tailnet only (+80/443 on preview). Outbound: allowlisted
# ports. The working user is blocked from the cloud metadata service.
# Rules are rebuilt from scratch on every run so the result is deterministic.

PUB_IF="$(public_if)"

ufw --force reset >/dev/null
# ufw reset moves the rules files aside; drop the backups to keep /etc/ufw tidy.
rm -f /etc/ufw/*.rules.[0-9]* /etc/ufw/*.rules.*_* 2>/dev/null || true

ufw default deny incoming  >/dev/null
ufw default deny outgoing  >/dev/null
ufw default deny routed    >/dev/null

ufw allow in on tailscale0  comment 'tailnet (ACLs decide)' >/dev/null
ufw allow out on tailscale0 comment 'tailnet' >/dev/null

ufw allow out 53        comment 'DNS'            >/dev/null
ufw allow out 123/udp   comment 'NTP'            >/dev/null
ufw allow out 80/tcp    comment 'HTTP egress'    >/dev/null
ufw allow out 443/tcp   comment 'HTTPS egress'   >/dev/null
ufw allow out 443/udp   comment 'HTTP/3 egress'  >/dev/null
ufw allow out 41641/udp comment 'Tailscale'      >/dev/null
ufw allow out 3478/udp  comment 'Tailscale STUN' >/dev/null
ufw allow 41641/udp     comment 'Tailscale direct' >/dev/null
for p in $EGRESS_EXTRA; do
    ufw allow out "$p" comment 'EGRESS_EXTRA' >/dev/null
done

if [ "$ROLE" = "preview" ]; then
    ufw allow in on "$PUB_IF" to any port 80  proto tcp comment 'HTTP (preview)'  >/dev/null
    ufw allow in on "$PUB_IF" to any port 443 proto tcp comment 'HTTPS (preview)' >/dev/null
fi

# Metadata service: agents running as the working user must not read
# user-data or instance credentials. Root (cloud-init, provider agents) keeps access.
uid="$(id -u "$ROCK_USER")"
ensure_block /etc/ufw/before.rules ROCK-METADATA <<EOF || true
*filter
-I ufw-before-output 1 -d 169.254.169.254/32 -m owner --uid-owner ${uid} -j REJECT
COMMIT
EOF

# Docker publishes ports via its own chains and bypasses ufw; DOCKER-USER
# re-applies policy. Lives here (not in docker.sh) because ufw reset above
# restores after.rules to package defaults.
if has_module docker; then
    ensure_block /etc/ufw/after.rules ROCK-DOCKER-USER <<EOF || true
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A DOCKER-USER ! -i ${PUB_IF} -j RETURN
-A DOCKER-USER -i ${PUB_IF} -p tcp -m multiport --dports 80,443 -j RETURN
-A DOCKER-USER -i ${PUB_IF} -j DROP
COMMIT
EOF
fi

# Lockout guard: without Tailscale the only way in would be the provider console.
rm -f "$ROCK_STATE_DIR/lockout-guard"
if ! tailscale_up; then
    warn "tailscale is not up; opening 22/tcp publicly (rate limited) to avoid lockout"
    ufw limit in on "$PUB_IF" to any port 22 proto tcp comment 'LOCKOUT GUARD - remove' >/dev/null
    touch "$ROCK_STATE_DIR/lockout-guard"
fi

ufw --force enable >/dev/null
log "ufw enabled (public if: $PUB_IF)"
