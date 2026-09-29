# shellcheck shell=bash
# Prerequisites for srt / Claude Code sandboxing on Linux: bubblewrap + socat,
# and an AppArmor profile that lets bwrap (only) create user namespaces.
# Ubuntu >= 23.10 restricts unprivileged userns; we keep that restriction on
# globally and exempt bwrap, rather than flipping the sysctl (guide §6).

apt_install bubblewrap socat ripgrep

if [ -d /etc/apparmor.d ]; then
    write_file /etc/apparmor.d/bwrap 0644 <<'EOF' && apparmor_parser -r /etc/apparmor.d/bwrap || true
# Managed by rock (provision/modules/sandbox.sh)
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,

  include if exists <local/bwrap>
}
EOF
fi
