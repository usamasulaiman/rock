# shellcheck shell=bash
# Agent harnesses: Claude Code (native installer, per user), pi and srt (global npm).

# pi bundles esbuild (extension loading), whose postinstall newer npm skips by default.
npm install -g --no-fund --no-audit --allow-scripts=esbuild,protobufjs \
    @earendil-works/pi-coding-agent \
    @anthropic-ai/sandbox-runtime >/dev/null

# shellcheck disable=SC2016  # expanded by the user's shell
if ! as_user "$ROCK_USER" 'test -x "$HOME/.local/bin/claude"'; then
    as_user "$ROCK_USER" 'curl -fsSL https://claude.ai/install.sh | bash'
fi
