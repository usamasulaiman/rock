# shellcheck shell=bash
# Caddy with the Cloudflare DNS plugin (DNS-01 certs). Preview role only.
# Site config is owned by whatever deploys previews: this module only writes a
# base Caddyfile that imports /etc/caddy/sites/*.caddy.
# The Cloudflare token comes from Doppler at runtime, never from user-data.

add_apt_repo caddy https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    "deb [signed-by=/etc/apt/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main"
apt_update
apt_install caddy libcap2-bin

# Stock package lacks the DNS plugin; swap in an official build that has it.
if ! caddy list-modules 2>/dev/null | grep -q '^dns.providers.cloudflare$'; then
    curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$(arch)&p=github.com/caddy-dns/cloudflare" \
        -o /usr/bin/caddy.new
    chmod 0755 /usr/bin/caddy.new
    mv -f /usr/bin/caddy.new /usr/bin/caddy
    setcap 'cap_net_bind_service=+ep' /usr/bin/caddy
    apt-mark hold caddy >/dev/null
fi

install -d -m 0755 /etc/caddy/sites
write_file /etc/caddy/Caddyfile 0644 <<'EOF' || true
# Managed by rock (provision/modules/caddy.sh). Add sites in /etc/caddy/sites/.
{
	acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}

(preview_headers) {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		X-Robots-Tag "noindex, nofollow"
	}
}

import /etc/caddy/sites/*.caddy
EOF

# Doppler injects CLOUDFLARE_API_TOKEN once a service token is installed with
# `bin/apply --doppler-token`; until then Caddy runs without DNS-01.
write_file /etc/systemd/system/caddy.service.d/10-doppler.conf 0644 <<'EOF' && systemctl daemon-reload || true
[Service]
EnvironmentFile=-/etc/rock/doppler.env
ExecStart=
ExecStart=/bin/sh -c 'if [ -n "$$DOPPLER_TOKEN" ]; then exec /usr/bin/doppler run -- /usr/bin/caddy run --environ --config /etc/caddy/Caddyfile; else exec /usr/bin/caddy run --environ --config /etc/caddy/Caddyfile; fi'
EOF

if [ "$(ls -A /etc/caddy/sites)" = "" ]; then
    for d in $(printf '%s' "$CADDY_DOMAINS" | tr ',' ' '); do
        write_file "/etc/caddy/sites/${d}.caddy" 0644 <<EOF || true
${d} {
	import preview_headers
	reverse_proxy 127.0.0.1:8080
}
EOF
    done
fi

systemctl enable caddy
systemctl restart caddy || warn "caddy failed to start (missing Cloudflare token?)"
