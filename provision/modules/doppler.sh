# shellcheck shell=bash
# Doppler CLI. The service token is installed later by `bin/apply --doppler-token`
# into /etc/rock/doppler.env (root:$ROCK_USER 0640), never via user-data (guide D14).

add_apt_repo doppler https://packages.doppler.com/public/cli/gpg.DE2A7741A397C129.key \
    "deb [signed-by=/etc/apt/keyrings/doppler.gpg] https://packages.doppler.com/public/cli/deb/debian any-version main"
apt_update
apt_install doppler

if [ -f /etc/rock/doppler.env ]; then
    chown "root:$ROCK_USER" /etc/rock/doppler.env
    chmod 0640 /etc/rock/doppler.env
fi
