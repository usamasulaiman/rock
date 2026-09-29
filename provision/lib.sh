#!/usr/bin/env bash
# Shared helpers for provision modules. Sourced, never executed.
# shellcheck disable=SC2034  # variables are consumed by modules

ROCK_CONFIG="${ROCK_CONFIG:-/etc/rock/config.env}"
ROCK_STATE_DIR="${ROCK_STATE_DIR:-/var/lib/rock}"

log()  { printf '[rock] %s\n' "$*"; }
warn() { printf '[rock] WARN: %s\n' "$*" >&2; }
die()  { printf '[rock] ERROR: %s\n' "$*" >&2; exit 1; }

# write_file PATH MODE <<'EOF' ... EOF
# Atomically writes stdin to PATH. Returns 0 if the file changed, 1 if unchanged,
# so callers can restart services only when needed.
write_file() {
    local path="$1" mode="${2:-0644}" tmp
    mkdir -p "$(dirname "$path")"
    tmp="$(mktemp "${path}.XXXXXX")"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$path"
    return 0
}

# Replace a marked block in a file (or append it). Idempotent.
# ensure_block FILE MARKER <<'EOF' ... EOF
ensure_block() {
    local file="$1" marker="$2" body tmp
    body="$(cat)"
    tmp="$(mktemp)"
    if [ -f "$file" ]; then
        awk -v b="# BEGIN ${marker}" -v e="# END ${marker}" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip { print }
        ' "$file" > "$tmp"
    fi
    printf '# BEGIN %s\n%s\n# END %s\n' "$marker" "$body" "$marker" >> "$tmp"
    if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

apt_updated=0
apt_update() {
    if [ "$apt_updated" -eq 0 ]; then
        apt-get update -q
        apt_updated=1
    fi
}

# add_apt_repo NAME KEY_URL "deb [...] URL SUITE COMPONENTS"
# The deb line may reference /etc/apt/keyrings/NAME.gpg as signed-by.
add_apt_repo() {
    local name="$1" key_url="$2" line="$3"
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -s "/etc/apt/keyrings/${name}.gpg" ]; then
        curl -fsSL "$key_url" | gpg --dearmor --yes -o "/etc/apt/keyrings/${name}.gpg"
        chmod a+r "/etc/apt/keyrings/${name}.gpg"
    fi
    if printf '%s\n' "$line" | write_file "/etc/apt/sources.list.d/${name}.list" 0644; then
        apt_updated=0
    fi
}

arch()     { dpkg --print-architecture; }
# shellcheck source=/dev/null
codename() { . /etc/os-release && printf '%s' "$VERSION_CODENAME"; }

as_user() {
    local user="$1"; shift
    sudo -u "$user" -H bash -lc "$*"
}

has_module() {
    local m
    for m in $MODULES; do [ "$m" = "$1" ] && return 0; done
    return 1
}

public_if() {
    local ifc
    ifc="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    printf '%s' "${ifc:-eth0}"
}

tailscale_up() {
    command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1
}

# Remove a KEY=... line from the config file (used to scrub one-shot secrets).
scrub_config_key() {
    local key="$1"
    [ -f "$ROCK_CONFIG" ] || return 0
    sed -i "/^${key}=/d" "$ROCK_CONFIG"
}
