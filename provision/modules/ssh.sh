# shellcheck shell=bash
# sshd hardening. Reachability (Tailscale-only) is enforced by the firewall
# module, not ListenAddress: Ubuntu 24.04 socket-activates sshd and binding to
# the Tailscale IP races tailscaled at boot (guide D17).

# Remove the drop-in the old vps-hardening.sh left behind, if present.
rm -f /etc/ssh/sshd_config.d/98-tailscale-only.conf

changed=0
write_file /etc/ssh/sshd_config.d/99-rock-hardening.conf 0644 <<EOF && changed=1
# Managed by rock (provision/modules/ssh.sh)
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
UsePAM yes
AllowUsers ${ROCK_USER}
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 60
ClientAliveCountMax 10
MaxSessions 20
MaxStartups 10:30:60
AllowAgentForwarding no
AllowTcpForwarding local
X11Forwarding no
PermitTunnel no
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF

if [ "$changed" -eq 1 ]; then
    sshd -t || die "sshd config validation failed; not restarting"
    systemctl daemon-reload
    systemctl restart ssh.socket 2>/dev/null || true
    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
fi
