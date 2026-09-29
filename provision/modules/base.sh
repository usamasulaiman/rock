# shellcheck shell=bash
# Base system: packages, sysctl, limits, swap, journald, unattended-upgrades.

export DEBIAN_FRONTEND=noninteractive
apt_update
apt-get upgrade -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
apt_install openssh-server ufw unattended-upgrades apt-listchanges ca-certificates curl wget gnupg \
    lsb-release iptables iproute2 jq sqlite3 git rsync acl
apt-get purge -y -q exim4 postfix whois finger rsh-client telnet 2>/dev/null || true
apt-get autoremove -y -q

write_file /etc/sysctl.d/99-rock-hardening.conf 0644 <<'EOF' || true
# Managed by rock (provision/modules/base.sh)
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.icmp_ratelimit = 1000
net.ipv4.tcp_rfc1337 = 1
net.netfilter.nf_conntrack_max = 524288
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
vm.swappiness = 10
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288
net.core.somaxconn = 4096
EOF
modprobe nf_conntrack 2>/dev/null || true
sysctl --system >/dev/null || warn "some sysctl keys failed to apply"

write_file /etc/security/limits.d/99-rock.conf 0644 <<'EOF' || true
* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768
EOF

write_file /etc/systemd/journald.conf.d/99-rock.conf 0644 <<'EOF' && systemctl restart systemd-journald || true
[Journal]
SystemMaxUse=500M
MaxRetentionSec=30day
EOF

write_file /etc/apt/apt.conf.d/50unattended-upgrades 0644 <<EOF || true
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "${AUTO_REBOOT}";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

if [ "$SWAP_MB" -gt 0 ] && [ ! -f /swapfile ]; then
    log "creating ${SWAP_MB}MB swap"
    fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null \
        || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
