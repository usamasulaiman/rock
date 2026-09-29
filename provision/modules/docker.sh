# shellcheck shell=bash
# Docker engine + compose. Firewall rules for published ports live in firewall.sh.
# Membership in the docker group is root-equivalent; on dev hosts sandboxed jobs
# are denied the socket by catapult's srt profiles.

add_apt_repo docker https://download.docker.com/linux/ubuntu/gpg \
    "deb [arch=$(arch) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(codename) stable"
apt_update
apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

write_file /etc/docker/daemon.json 0644 <<'EOF' && systemctl restart docker || true
{
  "icc": false,
  "userland-proxy": false,
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" },
  "live-restore": true
}
EOF
systemctl enable --now docker
usermod -aG docker "$ROCK_USER"
