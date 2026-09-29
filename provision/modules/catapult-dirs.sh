# shellcheck shell=bash
# Directories catapult expects (guide §4 contract). catapult owns what goes inside.

install -d -m 0750 -o "$ROCK_USER" -g "$ROCK_USER" \
    /srv/catapult /srv/catapult/data /srv/catapult/worktrees /srv/catapult/repos
