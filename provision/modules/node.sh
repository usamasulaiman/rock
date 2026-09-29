# shellcheck shell=bash
# Node.js LTS from NodeSource (amd64 + arm64), pnpm through corepack.

NODE_MAJOR="${NODE_MAJOR:-24}"

add_apt_repo nodesource https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    "deb [arch=$(arch) signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main"
apt_update
apt_install nodejs build-essential

# Global npm installs go to /usr/lib/node_modules (root-owned); user-level
# tools install into ~/.local via the user's own npm prefix.
corepack enable
as_user "$ROCK_USER" 'corepack prepare pnpm@latest --activate >/dev/null'

home="$(getent passwd "$ROCK_USER" | cut -d: -f6)"
ensure_block "$home/.profile" ROCK-PATH <<'EOF' || true
export PATH="$HOME/.local/bin:$PATH"
EOF
chown "$ROCK_USER:$ROCK_USER" "$home/.profile"
