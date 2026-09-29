# shellcheck shell=bash
# Non-root working user with key-only SSH and passwordless sudo.
# The user has no password, so NOPASSWD is the only usable sudo mode; access
# control is SSH keys + Tailscale ACLs.

if ! id "$ROCK_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$ROCK_USER"
fi
usermod -aG sudo "$ROCK_USER"

printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ROCK_USER" \
    | write_file "/etc/sudoers.d/90-rock-${ROCK_USER}" 0440 || true
visudo -cf "/etc/sudoers.d/90-rock-${ROCK_USER}" >/dev/null \
    || { rm -f "/etc/sudoers.d/90-rock-${ROCK_USER}"; die "sudoers validation failed"; }

home="$(getent passwd "$ROCK_USER" | cut -d: -f6)"
install -d -m 0700 -o "$ROCK_USER" -g "$ROCK_USER" "$home/.ssh"
# SSH_PUBLIC_KEYS may hold several keys separated by newlines or '|'.
printf '%s\n' "$SSH_PUBLIC_KEYS" | tr '|' '\n' | sed '/^[[:space:]]*$/d' \
    | write_file "$home/.ssh/authorized_keys" 0600 || true
chown "$ROCK_USER:$ROCK_USER" "$home/.ssh/authorized_keys"

while read -r key; do
    case "$key" in
        ssh-ed25519\ *|ecdsa-sha2-nistp*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *|ssh-rsa\ *) ;;
        *) die "invalid SSH public key: ${key:0:30}..." ;;
    esac
done < "$home/.ssh/authorized_keys"

# Close the stale-root-key vector left by some provider images.
rm -f /root/.ssh/authorized_keys
