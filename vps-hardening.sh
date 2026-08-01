#!/bin/bash
# VPS Security Hardening Script (Generic, Ubuntu, Docker-first)
# Run as root on a fresh Ubuntu VPS.
# Usage: sudo bash vps-hardening.sh
#
# Interactive prompts drive optional components. Always-on core is minimal
# so the script is safe on a 1GB RAM VPS.

set -euo pipefail

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

if [ ! -f /etc/os-release ] || ! grep -q '^NAME="Ubuntu' /etc/os-release; then
    echo "This script targets Ubuntu only. Aborting."
    exit 1
fi

# Public interface auto-detection
PUBLIC_IF=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
if [ -z "${PUBLIC_IF}" ]; then
    echo "Warning: could not detect default public interface. Falling back to eth0."
    PUBLIC_IF="eth0"
fi

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

prompt_str() {
    local var="$1" msg="$2" default="${3:-}"
    local val
    if [ -n "$default" ]; then
        read -rp "${msg} [${default}]: " val
        val="${val:-$default}"
    else
        while true; do
            read -rp "${msg}: " val
            [ -n "$val" ] && break
            echo "  (required)"
        done
    fi
    printf -v "$var" '%s' "$val"
}

prompt_yn() {
    local var="$1" msg="$2" default="${3:-n}"
    local val
    read -rp "${msg} [y/N] (default ${default}): " val
    val="${val:-$default}"
    case "${val,,}" in
        y|yes) printf -v "$var" 'y' ;;
        *)     printf -v "$var" 'n' ;;
    esac
}

prompt_int() {
    local var="$1" msg="$2" default="${3:-0}"
    prompt_str "$var" "$msg" "$default"
    printf -v "$var" '%d' "${!var}" 2>/dev/null || printf -v "$var" '%d' "$default"
}

# ---------------------------------------------------------------------------
# Collect configuration
# ---------------------------------------------------------------------------

echo "=== VPS Security Hardening (Generic, Docker-first) ==="
echo ""

prompt_str  DEPLOY_USER        "Deploy username"
prompt_int  SSH_PORT           "SSH port" 22
prompt_str  SSH_PUBLIC_KEY     "SSH public key (ssh-ed25519/ssh-rsa ...)"
prompt_int  SWAP_MB            "Swap size in MB (0 to skip)" 2048
prompt_yn   SSH_TAILSCALE_ONLY "Bind SSH to Tailscale interface only (strongly recommended)?" y
prompt_yn   INSTALL_GVISOR     "Install gVisor (runsc) for sandboxing user-supplied code?" n
prompt_yn   INSTALL_DOPPLER    "Install Doppler CLI?" y
if [ "$INSTALL_DOPPLER" = "y" ]; then
    prompt_str DOPPLER_TOKEN   "Doppler service token"
fi
prompt_yn   INSTALL_CADDY      "Install Caddy reverse proxy?" y
if [ "$INSTALL_CADDY" = "y" ]; then
    prompt_str CADDY_CF_TOKEN  "Cloudflare API token (DNS-01)"
    prompt_str CADDY_DOMAINS   "Domains (comma-separated, e.g. app.example.com,api.example.com)"
fi
prompt_yn   INSTALL_TAILSCALE  "Install Tailscale?" y
if [ "$INSTALL_TAILSCALE" = "y" ]; then
    prompt_str TS_AUTH_KEY     "Tailscale auth key (tskey-...) (leave blank to auth later)"
fi
prompt_yn   INSTALL_PI         "Install Pi coding agent (pi.dev)?" y

prompt_yn   INSTALL_RESTIC     "Install restic backups?" n
if [ "$INSTALL_RESTIC" = "y" ]; then
    prompt_str RESTIC_REPO     "Restic repo URL (e.g. s3:s3.amazonaws.com/bucket/path or rest:http://...)"
    prompt_str RESTIC_PASS     "Restic repo password"
    prompt_str RESTIC_PATHS    "Paths to back up" "/opt /home /etc/docker"
fi

prompt_yn   INSTALL_AIDE       "Install AIDE file-integrity monitoring?" n
prompt_yn   INSTALL_FALCO      "Install Falco runtime security (~40MB RAM)?" n
TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
if [ "$INSTALL_FALCO" = "y" ] && [ "$TOTAL_RAM_MB" -lt 2048 ]; then
    echo "Warning: Falco on ${TOTAL_RAM_MB}MB RAM may cause memory pressure."
fi

prompt_yn   INSTALL_LITELLM    "Install LiteLLM router + sqlite/sqlite-vec memory stack?" n
if [ "$INSTALL_LITELLM" = "y" ]; then
    prompt_str LITELLM_DIR     "Compose project dir" "/opt/llm-infra"
fi

prompt_yn   INSTALL_AUTHENTIK  "Install Authentik SSO (note: uses postgres, heavy on 1GB)?" n
if [ "$INSTALL_AUTHENTIK" = "y" ] && [ "$TOTAL_RAM_MB" -lt 2048 ]; then
    echo "Warning: Authentik + Postgres on ${TOTAL_RAM_MB}MB RAM is not recommended."
fi

prompt_yn   AUTO_REBOOT        "Enable automatic reboot after kernel security updates?" n

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

echo ""
echo "=== Configuration Summary ==="
echo "Deploy user        : ${DEPLOY_USER}"
echo "SSH port           : ${SSH_PORT}"
echo "SSH tailscale-only : ${SSH_TAILSCALE_ONLY}"
echo "Swap (MB)          : ${SWAP_MB}"
echo "gVisor             : ${INSTALL_GVISOR}"
echo "Doppler            : ${INSTALL_DOPPLER}"
echo "Caddy              : ${INSTALL_CADDY}"
echo "Tailscale          : ${INSTALL_TAILSCALE}"
echo "Pi coding agent    : ${INSTALL_PI}"
echo "Restic backups     : ${INSTALL_RESTIC}"
echo "AIDE               : ${INSTALL_AIDE}"
echo "Falco              : ${INSTALL_FALCO}"
echo "LiteLLM stack      : ${INSTALL_LITELLM}"
echo "Authentik          : ${INSTALL_AUTHENTIK}"
echo "Auto-reboot        : ${AUTO_REBOOT}"
echo "Public interface   : ${PUBLIC_IF}"
echo "Total RAM (MB)     : ${TOTAL_RAM_MB}"
echo ""
read -p "Continue? (yes/no): " -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# ---------------------------------------------------------------------------
# Helper: atomic file write
# ---------------------------------------------------------------------------

write_file() {
    local path="$1"
    local content="$2"
    local mode="${3:-0644}"
    local tmp="${path}.tmp.$$"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$path"
}

# ---------------------------------------------------------------------------
# 1. System update
# ---------------------------------------------------------------------------

echo "[1/N] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    ufw fail2ban unattended-upgrades apt-listchanges \
    ca-certificates curl wget gnupg lsb-release \
    iptables iproute2 jq sqlite3

# ---------------------------------------------------------------------------
# 2. Remove unused / insecure packages
# ---------------------------------------------------------------------------

echo "[2/N] Removing unused packages..."
apt-get purge -y exim4 postfix whois finger rsh-client telnet 2>/dev/null || true
apt-get autoremove -y

# ---------------------------------------------------------------------------
# 3. Create deploy user
# ---------------------------------------------------------------------------

echo "[3/N] Creating deploy user..."
if id "${DEPLOY_USER}" &>/dev/null; then
    echo "  User ${DEPLOY_USER} already exists."
else
    useradd -m -s /bin/bash "${DEPLOY_USER}"
    usermod -aG sudo "${DEPLOY_USER}"
fi

# Sudoers: require password, log usage
write_file "/etc/sudoers.d/${DEPLOY_USER}" "${DEPLOY_USER} ALL=(ALL) ALL
Defaults:${DEPLOY_USER} logfile=\"/var/log/sudo.log\"
" 0440
touch /var/log/sudo.log
chmod 600 /var/log/sudo.log

# ---------------------------------------------------------------------------
# 4. SSH key for deploy user
# ---------------------------------------------------------------------------

echo "[4/N] Setting up SSH authorized_keys..."
mkdir -p "/home/${DEPLOY_USER}/.ssh"
printf '%s\n' "${SSH_PUBLIC_KEY}" > "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chmod 700 "/home/${DEPLOY_USER}/.ssh"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"

# Remove root's authorized_keys (closes stale-key vector)
if [ -f /root/.ssh/authorized_keys ]; then
    echo "  Removing /root/.ssh/authorized_keys"
    rm -f /root/.ssh/authorized_keys
fi

# ---------------------------------------------------------------------------
# 5. sysctl hardening
# ---------------------------------------------------------------------------

echo "[5/N] Applying sysctl hardening..."
write_file /etc/sysctl.d/99-hardening.conf "#
# VPS hardening sysctl settings
#
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 0
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
vm.swappiness = 10
fs.file-max = 1048576
net.core.somaxconn = 4096
"
sysctl --system

# ---------------------------------------------------------------------------
# 6. SSH hardening
# ---------------------------------------------------------------------------

echo "[6/N] Hardening SSH..."
SSHD_CONF="# SSH Hardening
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
AllowUsers ${DEPLOY_USER}
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
MaxSessions 4
MaxStartups 10:30:60
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm,hmac-sha2-256-etm
"
write_file /etc/ssh/sshd_config.d/99-hardening.conf "$SSHD_CONF"

# If Tailscale-only SSH, we'll bind to the tailnet address after tailscale
# is up. For now, leave a marker file so the tailscale install step updates it.
if [ "$SSH_TAILSCALE_ONLY" = "y" ]; then
    write_file /etc/ssh/sshd_config.d/98-tailscale-only.conf "# Bind SSH to Tailscale only.
# Populated by vps-hardening.sh after Tailscale is up.
# ListenAddress <tailscale_ip>
"
fi

# Backup original sshd_config once
if [ ! -f /etc/ssh/sshd_config.orig-hardening ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.orig-hardening
fi

# ---------------------------------------------------------------------------
# 7. UFW + DOCKER-USER chain rules
# ---------------------------------------------------------------------------

echo "[7/N] Configuring UFW + DOCKER-USER firewall rules..."
ufw --force disable
ufw --force reset

ufw default deny incoming
ufw default deny outgoing

# Outbound allow
ufw allow out 53/udp   comment 'DNS UDP'      >/dev/null
ufw allow out 53/tcp   comment 'DNS TCP'      >/dev/null
ufw allow out 123/udp  comment 'NTP'         >/dev/null
ufw allow out 80/tcp   comment 'HTTP egress'  >/dev/null
ufw allow out 443/tcp  comment 'HTTPS egress' >/dev/null
ufw allow out 41641/udp comment 'Tailscale'  >/dev/null

# Inbound: SSH rate-limited; 80/443 only if Caddy installed
if [ "$SSH_TAILSCALE_ONLY" = "n" ]; then
    ufw limit "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
fi
if [ "$INSTALL_CADDY" = "y" ]; then
    ufw allow 80/tcp  comment 'HTTP (Caddy)'  >/dev/null
    ufw allow 443/tcp comment 'HTTPS (Caddy)' >/dev/null
fi

# Hand-written DOCKER-USER chain rules (Docker bypasses UFW; this is the fix).
# We DROP everything on the public IF in DOCKER-USER, then allow only 80/443
# to published container ports.
DOCKER_USER_RULES_PATH=/etc/ufw/after.rules
if ! grep -q "VPS-HARDENING-DOCKER-USER" "$DOCKER_USER_RULES_PATH" 2>/dev/null; then
    cat >> "$DOCKER_USER_RULES_PATH" <<EOF

# ---- VPS-HARDENING-DOCKER-USER (do not edit) ----
# Docker bypasses UFW via the DOCKER-USER chain. These rules re-apply policy.
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i ${PUBLIC_IF} -j DROP
-A DOCKER-USER -i ${PUBLIC_IF} -p tcp -m tcp --dport 80 -j ACCEPT
-A DOCKER-USER -i ${PUBLIC_IF} -p tcp -m tcp --dport 443 -j ACCEPT
COMMIT
# ---- end VPS-HARDENING-DOCKER-USER ----
EOF
fi

# ---------------------------------------------------------------------------
# 8. fail2ban
# ---------------------------------------------------------------------------

echo "[8/N] Configuring fail2ban..."
write_file /etc/fail2ban/jail.local "[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
sendername = Fail2Ban
action = %(action_mwl)s

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 7200
" 0644

systemctl enable fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
# 9. Tailscale
# ---------------------------------------------------------------------------

if [ "$INSTALL_TAILSCALE" = "y" ]; then
    echo "[9/N] Installing Tailscale..."
    CODENAME="$(lsb_release -cs)"
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" \
        | gpg --dearmor -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.tailscale-keyring.list" \
        | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    apt-get update -y
    apt-get install -y tailscale

    if [ -n "${TS_AUTH_KEY:-}" ]; then
        tailscale up --authkey "${TS_AUTH_KEY}" --ssh=false
    else
        echo "  Tailscale installed. Run 'tailscale up' manually to authenticate."
    fi
    systemctl enable tailscaled

    # If SSH should bind to Tailscale only, update sshd_config and restart
    if [ "$SSH_TAILSCALE_ONLY" = "y" ]; then
        TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
        if [ -n "$TS_IP" ]; then
            write_file /etc/ssh/sshd_config.d/98-tailscale-only.conf "# Bind SSH to Tailscale only.
ListenAddress ${TS_IP}
"
        else
            echo "  Warning: could not detect Tailscale IPv4. SSH remains on all interfaces."
            echo "  Run 'tailscale up' then restart sshd manually."
        fi
    fi
else
    echo "[9/N] Tailscale skipped."
fi

# ---------------------------------------------------------------------------
# 10. Docker + compose plugin
# ---------------------------------------------------------------------------

echo "[10/N] Installing Docker + compose plugin..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
write_file /etc/apt/sources.list.d/docker.list "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable"
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Prepare daemon.json (extend if gVisor selected)
DAEMON_JSON='{
  "icc": false,
  "userland-proxy": false,
  "no-new-privileges": true,
  "userns-remap": "default",
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": 3 },
  "live-restore": true'
if [ "$INSTALL_GVISOR" = "y" ]; then
    DAEMON_JSON="${DAEMON_JSON},
  \"default-runtime\": \"runc\",
  \"runtimes\": { \"runsc\": { \"path\": \"/usr/bin/runsc\" } }"
fi
DAEMON_JSON="${DAEMON_JSON}
}"
write_file /etc/docker/daemon.json "$DAEMON_JSON"

# userns-remap setup: ensure subuid/subgid ranges exist
if ! grep -q "^${DEPLOY_USER}:" /etc/subuid 2>/dev/null; then
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${DEPLOY_USER}"
fi
if ! grep -q "^dockremap:" /etc/subuid 2>/dev/null; then
    useradd -r -s /usr/sbin/nologin dockremap 2>/dev/null || true
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 dockremap
fi

systemctl enable docker
systemctl restart docker

# Add deploy user to docker group
usermod -aG docker "${DEPLOY_USER}"

# ---------------------------------------------------------------------------
# 11. gVisor
# ---------------------------------------------------------------------------

if [ "$INSTALL_GVISOR" = "y" ]; then
    echo "[11/N] Installing gVisor (runsc)..."
    # Use the official gVisor apt repo for Ubuntu.
    curl -fsSL https://gvisor.dev/archive.key \
        | gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
    write_file /etc/apt/sources.list.d/gvisor.list "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases/released/apt $(dpkg --print-architecture) main"
    apt-get update -y
    apt-get install -y runsc
    # daemon.json already registers the runtime; no restart needed again.
else
    echo "[11/N] gVisor skipped."
fi

# ---------------------------------------------------------------------------
# 12. Caddy
# ---------------------------------------------------------------------------

if [ "$INSTALL_CADDY" = "y" ]; then
    echo "[12/N] Installing Caddy..."
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update -y
    apt-get install -y caddy

    # Build Caddyfile from domains list
    CADDYFILE=""
    IFS=',' read -ra DOMAIN_ARRAY <<< "$CADDY_DOMAINS"
    for domain in "${DOMAIN_ARRAY[@]}"; do
        domain=$(echo "$domain" | xargs)
        CADDYFILE="${CADDYFILE}${domain} {
    reverse_proxy 127.0.0.1:8080
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
    header {
        Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\"
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy no-referrer
    }
}

"
    done
    write_file /etc/caddy/Caddyfile "$CADDYFILE"

    # Cloudflare token in systemd override
    mkdir -p /etc/systemd/system/caddy.service.d
    write_file /etc/systemd/system/caddy.service.d/override.conf "[Service]
Environment=CLOUDFLARE_API_TOKEN=${CADDY_CF_TOKEN}
"
    systemctl daemon-reload
    systemctl enable caddy
    systemctl restart caddy
else
    echo "[12/N] Caddy skipped."
fi

# ---------------------------------------------------------------------------
# 13. Doppler CLI
# ---------------------------------------------------------------------------

if [ "$INSTALL_DOPPLER" = "y" ]; then
    echo "[13/N] Installing Doppler CLI..."
    curl -Ls https://cli.doppler.com/install.sh | sh
    mkdir -p /etc/doppler
    write_file /etc/doppler/token "${DOPPLER_TOKEN}" 0600
    # Make the token usable by deploy user via doppler (root-owned, group readable)
    chown root:"${DEPLOY_USER}" /etc/doppler/token
    chmod 640 /etc/doppler/token
else
    echo "[13/N] Doppler skipped."
fi

# ---------------------------------------------------------------------------
# 14. Pi coding agent
# ---------------------------------------------------------------------------

if [ "$INSTALL_PI" = "y" ]; then
    echo "[14/N] Installing Pi coding agent..."
    sudo -u "${DEPLOY_USER}" bash -c 'curl -fsSL https://pi.dev/install.sh | sh'
else
    echo "[14/N] Pi coding agent skipped."
fi

# ---------------------------------------------------------------------------
# 15. Restic backups
# ---------------------------------------------------------------------------

if [ "$INSTALL_RESTIC" = "y" ]; then
    echo "[15/N] Installing restic + cron..."
    apt-get install -y restic
    mkdir -p /etc/restic
    write_file /etc/restic/env "RESTIC_REPOSITORY=${RESTIC_REPO}
RESTIC_PASSWORD=${RESTIC_PASS}
RESTIC_PATHS=\"${RESTIC_PATHS}\"
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
" 0600
    write_file /etc/cron.d/restic-backup "# Restic daily backup
SHELL=/bin/bash
30 3 * * * root . /etc/restic/env && restic backup \$RESTIC_PATHS && restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
" 0644
    # Init repo (best-effort)
    . /etc/restic.env
    restic snapshots >/dev/null 2>&1 || restic init
else
    echo "[15/N] Restic skipped."
fi

# ---------------------------------------------------------------------------
# 16. AIDE
# ---------------------------------------------------------------------------

if [ "$INSTALL_AIDE" = "y" ]; then
    echo "[16/N] Installing AIDE..."
    apt-get install -y aide
    # Minimal config: watch key paths
    write_file /etc/aide/aide.conf.orig-gen "# Generated by vps-hardening.sh
database_in=file:/var/lib/aide/aide.db
database_out=file:/var/lib/aide/aide.db.new
database_new=file:/var/lib/aide/aide.db.new

# Rules
p = p+u+g+i+n+m+acl+xattrs
d = d+u+g+i+n+m+acl+xattrs

# Watch critical paths
/etc p
/opt p
/root p
/home p
/etc/docker p
/etc/caddy p
!/var/log
!/var/lib/aide
!/var/spool
!/proc
!/sys
!/dev
" 0640
    # Use distro config but add our paths to the database initialization.
    aideinit
    cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    write_file /etc/cron.d/aide-check "# AIDE weekly integrity check
SHELL=/bin/bash
0 4 * * 0 root /usr/bin/aide --check > /var/log/aide/aide-\$(date +\%F).log 2>&1
" 0644
    mkdir -p /var/log/aide
else
    echo "[16/N] AIDE skipped."
fi

# ---------------------------------------------------------------------------
# 17. Falco
# ---------------------------------------------------------------------------

if [ "$INSTALL_FALCO" = "y" ]; then
    echo "[17/N] Installing Falco..."
    curl -fsSL https://falco.org/repo/falcosecurity-packages.asc \
        | gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg
    write_file /etc/apt/sources.list.d/falco.list "deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] https://download.falco.org/packages/deb stable main"
    apt-get update -y
    apt-get install -y falco
    systemctl enable falco
    systemctl restart falco
else
    echo "[17/N] Falco skipped."
fi

# ---------------------------------------------------------------------------
# 18. LiteLLM stack
# ---------------------------------------------------------------------------

if [ "$INSTALL_LITELLM" = "y" ]; then
    echo "[18/N] Setting up LiteLLM + sqlite/sqlite-vec stack..."
    mkdir -p "${LITELLM_DIR}/data/memory"
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${LITELLM_DIR}"

    COMPOSE_FILE="${LITELLM_DIR}/docker-compose.yml"
    : > "${COMPOSE_FILE}"

    cat >> "${COMPOSE_FILE}" <<'YAML'
services:
  litellm:
    image: ghcr.io/berriai/litellm:main-latest
    container_name: litellm
    restart: unless-stopped
    ports:
      - "127.0.0.1:4000:4000"
    volumes:
      - ./data:/app/data
    environment:
      - LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
      # Doppler injects additional env (provider keys) at runtime
YAML

    if [ "$INSTALL_GVISOR" = "y" ]; then
        cat >> "${COMPOSE_FILE}" <<'YAML'
    runtime: runsc
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
YAML
    fi

    cat >> "${COMPOSE_FILE}" <<'YAML'
  memory:
    image: alpine:latest
    container_name: memory-store
    restart: unless-stopped
    volumes:
      - ./data/memory:/data
    command: >
      sh -c "apk add --no-cache sqlite && wget -qO /data/sqlite-vec.tar.gz
        https://github.com/asg017/sqlite-vec/releases/latest/download/sqlite-vec-static.tar.gz
        && tar -xzf /data/sqlite-vec.tar.gz -C /data
        && sqlite3 /data/memory.db '.databases'"
YAML

    if [ "$INSTALL_GVISOR" = "y" ]; then
        cat >> "${COMPOSE_FILE}" <<'YAML'
    runtime: runsc
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
YAML
    fi

    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${COMPOSE_FILE}"
    chmod 0640 "${COMPOSE_FILE}"
    echo "  LiteLLM stack written to ${COMPOSE_FILE}"
    echo "  Run with: doppler run --config prd -- docker compose -f ${COMPOSE_FILE} up -d"
else
    echo "[18/N] LiteLLM stack skipped."
fi

# ---------------------------------------------------------------------------
# 19. Authentik
# ---------------------------------------------------------------------------

if [ "$INSTALL_AUTHENTIK" = "y" ]; then
    echo "[19/N] Setting up Authentik (compose template)..."
    AUTH_DIR=/opt/authentik
    mkdir -p "${AUTH_DIR}"
    AUTHENTIK_COMPOSE='services:
  postgresql:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${PG_PASS}
      POSTGRES_USER: authentik
      POSTGRES_DB: authentik
    volumes:
      - ./data/pg:/var/lib/postgresql/data
  redis:
    image: redis:alpine
    restart: unless-stopped
  server:
    image: ghcr.io/goauthentik/server:latest
    restart: unless-stopped
    depends_on:
      - postgresql
      - redis
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9443:9443"
    environment:
      AUTHENTIK_POSTGRESQL__HOST: postgresql
      AUTHENTIK_POSTGRESQL__USER: authentik
      AUTHENTIK_POSTGRESQL__PASSWORD: ${PG_PASS}
      AUTHENTIK_POSTGRESQL__NAME: authentik
      AUTHENTIK_REDIS__HOST: redis
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY}
    volumes:
      - ./data/media:/media
      - ./data/templates:/templates
  worker:
    image: ghcr.io/goauthentik/server:latest
    restart: unless-stopped
    depends_on:
      - server
    command: worker
    environment:
      AUTHENTIK_POSTGRESQL__HOST: postgresql
      AUTHENTIK_POSTGRESQL__USER: authentik
      AUTHENTIK_POSTGRESQL__PASSWORD: ${PG_PASS}
      AUTHENTIK_POSTGRESQL__NAME: authentik
      AUTHENTIK_REDIS__HOST: redis
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY}
    volumes:
      - ./data/media:/media
      - ./data/templates:/templates
'
    write_file "${AUTH_DIR}/docker-compose.yml" "$AUTHENTIK_COMPOSE"
    write_file "${AUTH_DIR}/env.template" "PG_PASS=changeme
AUTHENTIK_SECRET_KEY=changeme
"
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${AUTH_DIR}"
    echo "  Authentik template written to ${AUTH_DIR}/docker-compose.yml"
    echo "  Edit ${AUTH_DIR}/env.template then 'doppler run -- docker compose up -d'"
else
    echo "[19/N] Authentik skipped."
fi

# ---------------------------------------------------------------------------
# 20. unattended-upgrades
# ---------------------------------------------------------------------------

echo "[20/N] Configuring unattended-upgrades..."
write_file /etc/apt/apt.conf.d/50unattended-upgrades 'Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "'"$AUTO_REBOOT"'";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
'

write_file /etc/apt/apt.conf.d/20auto-upgrades 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
'

# ---------------------------------------------------------------------------
# 21. Swap
# ---------------------------------------------------------------------------

if [ "$SWAP_MB" -gt 0 ]; then
    echo "[21/N] Setting up ${SWAP_MB}MB swap..."
    if [ ! -f /swapfile ]; then
        # fallocate can fail on some filesystems; fall back to dd
        if ! fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null; then
            echo "  fallocate failed, using dd (slower)..."
            dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_MB}" status=progress
        fi
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        if ! grep -q '^/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        sysctl vm.swappiness=10
    else
        echo "  /swapfile already exists, skipping."
    fi
else
    echo "[21/N] Swap skipped."
fi

# ---------------------------------------------------------------------------
# 22. Limits
# ---------------------------------------------------------------------------

echo "[22/N] Setting system limits..."
write_file /etc/security/limits.d/99-vps-hardening.conf "* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768
"

# ---------------------------------------------------------------------------
# 23. Working directory + SECURITY.md
# ---------------------------------------------------------------------------

echo "[23/N] Creating working directory and SECURITY.md..."
mkdir -p "/opt/${DEPLOY_USER}/"{scripts,backups,logs}
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/opt/${DEPLOY_USER}"

SECURITY_MD="# Security Setup for this VPS

Generated by vps-hardening.sh on $(date -u +'%Y-%m-%dT%H:%M:%SZ').

## Installed components

- Deploy user: \`${DEPLOY_USER}\`
- SSH port: \`${SSH_PORT}\`
- SSH tailscale-only: \`${SSH_TAILSCALE_ONLY}\`
- gVisor (runsc): \`${INSTALL_GVISOR}\`
- Doppler: \`${INSTALL_DOPPLER}\`
- Caddy: \`${INSTALL_CADDY}\`
- Tailscale: \`${INSTALL_TAILSCALE}\`
- Pi coding agent: \`${INSTALL_PI}\`
- Restic backups: \`${INSTALL_RESTIC}\`
- AIDE: \`${INSTALL_AIDE}\`
- Falco: \`${INSTALL_FALCO}\`
- LiteLLM stack: \`${INSTALL_LITELLM}\`
- Authentik: \`${INSTALL_AUTHENTIK}\`
- Auto-reboot after kernel updates: \`${AUTO_REBOOT}\`

## SSH access

   ssh -p ${SSH_PORT} ${DEPLOY_USER}@\$(tailscale ip -4)
"
if [ "$SSH_TAILSCALE_ONLY" = "y" ]; then
    SECURITY_MD="${SECURITY_MD}
SSH is bound to the Tailscale interface only. The public interface does not
listen on the SSH port. Fail2ban still protects against authenticated abuse."
else
    SECURITY_MD="${SECURITY_MD}
SSH is exposed on the public interface on port ${SSH_PORT}. Fail2ban protects
against brute force."
fi

if [ "$INSTALL_GVISOR" = "y" ]; then
    SECURITY_MD="${SECURITY_MD}

## gVisor (runsc)

gVisor is registered as a Docker runtime named \`runsc\`. The default runtime
remains \`runc\`. To sandbox a service that executes user-supplied code, set in
your docker-compose service:

    runtime: runsc
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true"
fi

if [ "$INSTALL_DOPPLER" = "y" ]; then
    SECURITY_MD="${SECURITY_MD}

## Doppler

Service token stored at /etc/doppler/token (mode 0640, root:\$(id -gn ${DEPLOY_USER})).

Invoke with secrets injected:

    doppler run --config prd -- docker compose up -d"
fi

if [ "$INSTALL_CADDY" = "y" ]; then
    SECURITY_MD="${SECURITY_MD}

## Caddy

Config at /etc/caddy/Caddyfile. Cloudflare DNS-01 challenge for TLS.
Reload after edits: \`systemctl reload caddy\`.
Cloudflare token lives in /etc/systemd/system/caddy.service.d/override.conf."
fi

if [ "$INSTALL_RESTIC" = "y" ]; then
    SECURITY_MD="${SECURITY_MD}

## Restic backups

Env at /etc/restic/env. Cron at /etc/cron.d/restic-backup (daily 03:30).
Test a restore with: \`. /etc/restic/env && restic snapshots\` then \`restic restore <id> --target /tmp/restore\`."
fi

if [ "$INSTALL_LITELLM" = "y" ]; then
    SECURITY_MD="${SECURITY_MD}

## LiteLLM stack

Compose at ${LITELLM_DIR}/docker-compose.yml. Exposed only on 127.0.0.1:4000;
Caddy should reverse-proxy to it publicly. Doppler injects provider keys:
\`doppler run --config prd -- docker compose -f ${LITELLM_DIR}/docker-compose.yml up -d\`"
fi

if [ "$INSTALL_AUTHENTIK" = "y" ]; then
    SECURITY_MD="${SECURITY_MD}

## Authentik

Compose at /opt/authentik/docker-compose.yml. Edit env.template first.
Internal-only ports; Caddy should front / on the authentik server."
fi

SECURITY_MD="${SECURITY_MD}

## Manual next steps

1. Test SSH access (keep this session open until verified).
2. If Tailscale-only SSH: verify \`ssh -p ${SSH_PORT} ${DEPLOY_USER}@\$(tailscale ip -4)\` works.
3. If fail2ban: \`fail2ban-client status sshd\`.
4. If Caddy: verify \`systemctl status caddy\` and TLS certs obtained.
5. If backups: verify \`restic snapshots\` after first cron run.
"

sudo -u "${DEPLOY_USER}" bash -c "cat > '/opt/${DEPLOY_USER}/SECURITY.md' <<'MD'
${SECURITY_MD}
MD"

# ---------------------------------------------------------------------------
# 24. Restart services
# ---------------------------------------------------------------------------

echo "[24/N] Restarting services with new config..."
if systemctl status ssh.service >/dev/null 2>&1; then
    systemctl restart ssh.service
elif systemctl status sshd.service >/dev/null 2>&1; then
    systemctl restart sshd.service
fi
systemctl restart fail2ban
if [ "$INSTALL_CADDY" = "y" ]; then
    systemctl reload caddy 2>/dev/null || systemctl restart caddy
fi

# Enable UFW last (after all rules are in place)
echo ""
echo "[25/N] Enabling UFW (last step, lockout-resistant)..."
ufw --force enable
ufw status verbose

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------

echo ""
echo "=== Security Hardening Complete ==="
echo ""
echo "IMPORTANT: Save this information!"
echo "=================================="
echo "1. SSH Port         : ${SSH_PORT}"
echo "2. Deploy user      : ${DEPLOY_USER}"
echo "3. SSH Tailscale-only: ${SSH_TAILSCALE_ONLY}"
echo "4. gVisor           : ${INSTALL_GVISOR}"
echo "5. Caddy domains    : ${CADDY_DOMAINS:-n/a}"
if [ "$SSH_TAILSCALE_ONLY" = "y" ] && [ "$INSTALL_TAILSCALE" = "y" ]; then
    echo "6. SSH command      : ssh -p ${SSH_PORT} ${DEPLOY_USER}@\$(tailscale ip -4)"
else
    echo "6. SSH command      : ssh -p ${SSH_PORT} ${DEPLOY_USER}@<VPS_PUBLIC_IP>"
fi
echo ""
echo "Next steps:"
echo "1. TEST your SSH access in a new terminal BEFORE closing this one."
echo "2. Read /opt/${DEPLOY_USER}/SECURITY.md"
echo "3. If Doppler: run 'doppler login' or use the service token."
echo "4. If Tailscale auth key was blank: run 'tailscale up'."
echo ""
echo "Fail2ban status:"
fail2ban-client status sshd 2>/dev/null || echo "  (fail2ban not ready yet)"
echo ""
echo "=== Hardening script finished ==="