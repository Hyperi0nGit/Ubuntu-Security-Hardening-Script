#!/bin/bash
# Ubuntu 26.04 Security Hardening Script - Production Grade
# GitHub: https://github.com/gensecaihq/Ubuntu-Security-Hardening-Script
# License: MIT License
# Version: 5.0
# Optimized for Ubuntu 26.04 LTS and compatible desktop/server installs

# DISCLAIMER:
# This script is provided "AS IS" without warranty of any kind, express or implied.
# The author expressly disclaims any and all warranties, express or implied, including
# any warranties as to the usability, suitability or effectiveness of any methods or
# measures this script attempts to apply. By using this script, you agree that the
# author shall not be held liable for any damages resulting from the use of this script.

set -euo pipefail
IFS=$'
	'

readonly RED='[0;31m'
readonly GREEN='[0;32m'
readonly YELLOW='[0;33m'
readonly BLUE='[0;34m'
readonly NC='[0m'

readonly SCRIPT_VERSION="6.0"
readonly LOG_DIR="/var/log/security-hardening"
readonly LOG_FILE="${LOG_DIR}/hardening-$(date +%Y%m%d-%H%M%S).log"
readonly BACKUP_DIR="/var/backups/security-hardening"
readonly REPORT_FILE="${LOG_DIR}/hardening_report_$(date +%Y%m%d-%H%M%S).txt"
readonly UBUNTU_VERSION="26.04"

print_message() {
    local color="$1"
    local message="$2"
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] ${message}${NC}" | tee -a "$LOG_FILE"
}

error_exit() {
    print_message "$RED" "ERROR: $1"
    exit 1
}

setup_directories() {
    mkdir -p "$LOG_DIR" "$BACKUP_DIR"
    chmod 700 "$LOG_DIR" "$BACKUP_DIR"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
}

check_ubuntu_version() {
    if ! command -v lsb_release &> /dev/null; then
        error_exit "lsb_release not found. Is this Ubuntu?"
    fi

    local version
    version=$(lsb_release -rs)
    local codename
    codename=$(lsb_release -cs)

    print_message "$GREEN" "Detected Ubuntu version: ${version} (${codename})"

    if [[ "$version" != "$UBUNTU_VERSION" ]]; then
        print_message "$YELLOW" "WARNING: This script is optimized for Ubuntu ${UBUNTU_VERSION}."
        print_message "$YELLOW" "Current version: ${version}"
        read -rp "Continue anyway? (y/N): " reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            error_exit "User cancelled operation"
        fi
    fi
}

check_system_requirements() {
    print_message "$GREEN" "Checking system requirements..."
    local available_space
    available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 2097152 ]]; then
        error_exit "Insufficient disk space. At least 2GB required."
    fi

    local total_memory
    total_memory=$(free -m | awk 'NR==2 {print $2}')
    if [[ $total_memory -lt 1024 ]]; then
        print_message "$YELLOW" "WARNING: Low memory detected. Some operations may be slow."
    fi

    if systemd-detect-virt -cq; then
        print_message "$YELLOW" "WARNING: Running inside a container. Some hardening features may be unsupported."
    fi
}

backup_file() {
    local target="$1"
    if [[ -f "$target" ]]; then
        local backup_name="${BACKUP_DIR}/$(basename "$target").$(date +%Y%m%d-%H%M%S).bak"
        cp -p "$target" "$backup_name"
        stat -c "%a %U:%G" "$target" > "${backup_name}.meta"
        print_message "$GREEN" "Backed up $target to $backup_name"
    fi
}

update_system() {
    print_message "$GREEN" "Updating package lists and upgrading packages..."
    apt-get update || error_exit "Failed to update package lists"
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y         -o Dpkg::Options::="--force-confdef"         -o Dpkg::Options::="--force-confold" || error_exit "Failed to upgrade packages"
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y         -o Dpkg::Options::="--force-confdef"         -o Dpkg::Options::="--force-confold" || true
}

install_packages() {
    print_message "$GREEN" "Installing security packages..."
    local packages=(
        aide
        auditd
        audispd-plugins
        apparmor
        apparmor-utils
        apparmor-profiles
        clamav
        clamav-daemon
        clamav-freshclam
        unattended-upgrades
        update-notifier-common
        ufw
        fail2ban
        rkhunter
        chkrootkit
        lynis
        debsums
        apt-listchanges
        needrestart
        snapd
        chrony
        net-tools
        iproute2
        tcpdump
        nmap
        sysstat
        acct
        ubuntu-advantage-tools
        libpam-pwquality
        libpam-tmpdir
        libpam-cap
        libpam-modules-bin
        cryptsetup
        cryptsetup-initramfs
        openscap-scanner
        scap-security-guide
    )

    for package in "${packages[@]}"; do
        print_message "$BLUE" "Installing: $package"
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >/dev/null 2>&1; then
            print_message "$YELLOW" "WARNING: Could not install $package"
        fi
    done
}

configure_chrony_nts() {
    print_message "$GREEN" "Configuring Chrony with NTS..."
    if ! command -v chronyc &> /dev/null; then
        print_message "$YELLOW" "Chrony not installed; skipping Chrony configuration"
        return
    fi

    backup_file "/etc/chrony/chrony.conf"
    cat > /etc/chrony/chrony.conf <<'EOF'
# Ubuntu 26.04 Chrony configuration with NTS
server time.cloudflare.com iburst nts
server nts.ntp.se iburst nts
server time.google.com iburst nts
pool 0.ubuntu.pool.ntp.org iburst maxsources 4
pool 1.ubuntu.pool.ntp.org iburst maxsources 2
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
log measurements statistics tracking
bindcmdaddress 127.0.0.1
bindcmdaddress ::1
cmdport 0
ntsdumpdir /var/lib/chrony
nocerttimecheck 1
EOF

    systemctl restart chrony || true
    systemctl enable chrony || true
}

configure_aide() {
    print_message "$GREEN" "Configuring AIDE file integrity monitoring..."
    if ! command -v aide &> /dev/null; then
        print_message "$YELLOW" "AIDE not installed; skipping AIDE setup"
        return
    fi

    backup_file "/etc/aide/aide.conf"
    cat >> /etc/aide/aide.conf <<'EOF'

# Ubuntu 26.04 specific exclusions
!/snap/
!/var/snap/
!/var/lib/snapd/
!/run/snapd/
!/sys/
!/proc/
!/dev/
!/run/
!/var/lib/docker/
!/var/lib/containerd/
!/var/lib/lxc/
!/var/lib/lxd/
EOF

    aideinit || error_exit "AIDE initialization failed"
    if [[ -f /var/lib/aide/aide.db.new ]]; then
        mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
        chmod 600 /var/lib/aide/aide.db
    fi

    cat > /etc/systemd/system/aide-check.service <<'EOF'
[Unit]
Description=AIDE integrity check
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/aide --check
Nice=19
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

    cat > /etc/systemd/system/aide-check.timer <<'EOF'
[Unit]
Description=Run AIDE daily
Requires=aide-check.service

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload || true
    systemctl enable --now aide-check.timer || true
}

configure_auditd() {
    print_message "$GREEN" "Configuring auditd..."
    if ! command -v auditd &> /dev/null; then
        print_message "$YELLOW" "auditd not installed; skipping auditd setup"
        return
    fi

    backup_file "/etc/audit/auditd.conf"
    backup_file "/etc/audit/rules.d/audit.rules"

    cat > /etc/audit/auditd.conf <<'EOF'
local_events = yes
write_logs = yes
log_file = /var/log/audit/audit.log
log_group = adm
log_format = RAW
flush = INCREMENTAL_ASYNC
freq = 50
max_log_file = 8
num_logs = 5
priority_boost = 4
disp_qos = lossy
dispatcher = /sbin/audispd
name_format = HOSTNAME
max_log_file_action = ROTATE
space_left = 75
space_left_action = SYSLOG
admin_space_left = 50
admin_space_left_action = SUSPEND
disk_full_action = SUSPEND
disk_error_action = SUSPEND
EOF

    cat > /etc/audit/rules.d/hardening.rules <<'EOF'
-D
-b 16384
-f 1

# Authentication and identity
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# Sudo and SSH
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config

# System configuration
-w /etc/systemd/ -p wa -k systemd
-w /lib/systemd/ -p wa -k systemd

# AppArmor
-w /etc/apparmor.d/ -p wa -k apparmor

# Time and network
-w /etc/chrony/chrony.conf -p wa -k time_config
-w /etc/netplan/ -p wa -k network_config
-w /etc/hostname -p wa -k system-locale

# Privileged commands
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=4294967295 -k privileged
EOF

    if command -v augenrules &> /dev/null; then
        augenrules --load || true
    fi
    systemctl restart auditd || true
}

configure_apparmor() {
    print_message "$GREEN" "Configuring AppArmor..."
    if ! command -v aa-status &> /dev/null; then
        print_message "$YELLOW" "AppArmor tools not installed; skipping AppArmor setup"
        return
    fi

    systemctl enable --now apparmor || true
}

configure_ufw() {
    print_message "$GREEN" "Configuring UFW firewall..."
    if ! command -v ufw &> /dev/null; then
        print_message "$YELLOW" "UFW not installed; skipping firewall setup"
        return
    fi

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw logging low
    ufw --force enable || true

    cat > /etc/logrotate.d/ufw <<'EOF'
/var/log/ufw.log {
    rotate 12
    weekly
    compress
    missingok
    notifempty
    create 640 root adm
}
EOF
}

configure_fail2ban() {
    print_message "$GREEN" "Configuring Fail2Ban..."
    if ! command -v fail2ban-server &> /dev/null; then
        print_message "$YELLOW" "Fail2Ban not installed; skipping setup"
        return
    fi

    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5
backend = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 5
bantime = 10m
findtime = 10m
EOF

    systemctl enable --now fail2ban || true
}

check_ssh_keys_exist() {
    local has_keys=false
    for user_home in /root /home/*; do
        if [[ -f "${user_home}/.ssh/authorized_keys" ]] && [[ -s "${user_home}/.ssh/authorized_keys" ]]; then
            has_keys=true
            break
        fi
    done
    echo "$has_keys"
}

harden_ssh() {
    print_message "$GREEN" "Hardening SSH configuration..."
    backup_file "/etc/ssh/sshd_config"

    local password_auth="no"
    if [[ "$(check_ssh_keys_exist)" != "true" ]]; then
        password_auth="yes"
        print_message "$YELLOW" "No SSH authorized keys found. Leaving password authentication enabled to avoid lockout."
    fi

    cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
Protocol 2
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication ${password_auth}
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
MaxAuthTries 3
MaxSessions 10
StrictModes yes
HostbasedAuthentication no
IgnoreUserKnownHosts yes
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
SyslogFacility AUTH
LogLevel VERBOSE
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
ClientAliveInterval 300
ClientAliveCountMax 2
UseDNS no
PermitUserEnvironment no
DebianBanner no
PrintMotd no
PrintLastLog yes
PidFile /run/sshd.pid
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server -f AUTHPRIV -l INFO
EOF

    systemctl restart sshd || true
}

configure_unattended_upgrades() {
    print_message "$GREEN" "Configuring unattended upgrades..."
    local distro_id
    local distro_codename
    distro_id=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
    distro_codename=$(lsb_release -cs)

    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
    "${distro_id}:${distro_codename}-proposed";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::MinimalSteps "true";
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
}

configure_sysctl() {
    print_message "$GREEN" "Applying sysctl hardening settings..."
    cat > /etc/sysctl.d/99-security-hardening.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 2
kernel.kexec_load_disabled = 1
kernel.unprivileged_userns_clone = 0
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
vm.swappiness = 10
vm.vfs_cache_pressure = 50
fs.file-max = 65536
EOF

    sysctl --system || true
}

configure_systemd_security() {
    print_message "$GREEN" "Adding systemd hardening drop-ins..."
    mkdir -p /etc/systemd/system/sshd.service.d
    cat > /etc/systemd/system/sshd.service.d/99-hardening.conf <<'EOF'
[Service]
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictRealtime=yes
NoNewPrivileges=yes
MemoryDenyWriteExecute=yes
EOF

    systemctl daemon-reload || true
}

generate_report() {
    print_message "$GREEN" "Generating hardening report..."
    local ubuntu_ver
    ubuntu_ver=$(lsb_release -rs)
    local kernel_ver
    kernel_ver=$(uname -r)

    cat > "$REPORT_FILE" <<'EOF'
Ubuntu 26.04 Security Hardening Report
======================================
Generated: $(date)
Hostname: $(hostname)
Ubuntu Version: $ubuntu_ver
Kernel: $kernel_ver
Script Version: $SCRIPT_VERSION

Summary:
- Security packages installed and updated
- Chrony configured with NTS
- AIDE file integrity schedule created
- auditd configured
- AppArmor enabled
- UFW and Fail2Ban configured
- SSH hardened
- Unattended upgrades configured
- Sysctl hardening applied
EOF
}

main() {
    setup_directories
    check_root
    check_ubuntu_version
    check_system_requirements
    update_system
    install_packages
    configure_chrony_nts
    configure_aide
    configure_auditd
    configure_apparmor
    configure_ufw
    configure_fail2ban
    harden_ssh
    configure_unattended_upgrades
    configure_sysctl
    configure_systemd_security
    generate_report
    print_message "$GREEN" "Ubuntu 26.04 hardening complete."
}

main "$@"
