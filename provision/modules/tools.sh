# shellcheck shell=bash
# Everyday CLI tools: gh, ripgrep, herdr.

add_apt_repo githubcli https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    "deb [arch=$(arch) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main"
apt_update
apt_install gh ripgrep fd-find tmux htop unzip

# herdr's install method isn't pinned yet (guide §12); run whatever the host config says.
if [ -n "$HERDR_INSTALL_CMD" ]; then
    if ! as_user "$ROCK_USER" 'command -v herdr' >/dev/null 2>&1; then
        as_user "$ROCK_USER" "$HERDR_INSTALL_CMD"
    fi
else
    log "HERDR_INSTALL_CMD not set; skipping herdr"
fi
