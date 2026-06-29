# =============================================================================
# RHEL 9 Kickstart — Hardened Template Build
# Benchmark:   NIST SP 800-53 / CIS RHEL 9 aligned
# Domain:      Entra ID (Azure AD) joined via sssd
# Network:     DHCP
# Web Console: Cockpit enabled
# Agents:      CrowdStrike + ManageEngine installed post-clone
# =============================================================================
# PLACEHOLDERS — replace before use:
#   DOMAIN.COM        → your Entra ID domain FQDN (e.g. corp.contoso.com)
#   TENANT-ID         → your Azure tenant ID (GUID)
#   DC01.DOMAIN.COM   → your primary domain controller / internal DNS
#   DC02.DOMAIN.COM   → your secondary domain controller / internal DNS
#   LOCAL_ADMIN_HASH  → generate with: python3 -c "import crypt; print(crypt.crypt('PASSWORD', crypt.mksalt(crypt.METHOD_SHA512)))"
# =============================================================================

###############################################################################
# INSTALLATION METHOD
###############################################################################
# Comment out 'cdrom' and uncomment 'url' if installing from a network mirror
cdrom
# url --url="http://MIRROR.DOMAIN.COM/rhel9/BaseOS/x86_64/os/"

text
skipx
firstboot --disabled
reboot

###############################################################################
# LOCALE / KEYBOARD / TIMEZONE
###############################################################################
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts=us
timezone America/Chicago --utc --ntpservers=DC01.DOMAIN.COM,DC02.DOMAIN.COM

###############################################################################
# NETWORK — DHCP
# NIC name (ens192) is standard for VMware VMXNET3 on RHEL 9.
# Verify with your VMware environment; may be ens160 depending on adapter.
###############################################################################
network --bootproto=dhcp --device=ens192 --onboot=yes --ipv6=no \
        --nameserver=DC01.DOMAIN.COM,DC02.DOMAIN.COM \
        --hostname=rhel9-template.DOMAIN.COM

###############################################################################
# SECURITY
###############################################################################
selinux --enforcing
firewall --enabled --service=ssh --service=cockpit

###############################################################################
# AUTHENTICATION
# localadmin account — password auth enabled for initial access.
# SSH key should be injected post-clone; password auth will be disabled
# in sshd_config below but PAM still needs a password for console access.
###############################################################################
rootpw --lock
user --name=localadmin --groups=wheel --iscrypted --password=LOCAL_ADMIN_HASH

# sssd selected here; Entra ID integration configured in %post
authselect select sssd with-mkhomedir with-faillock --force

###############################################################################
# BOOTLOADER
###############################################################################
bootloader --append="audit=1 audit_backlog_limit=8192 slub_debug=P page_poison=1 \
            vsyscall=none ipv6.disable=1" \
           --location=mbr \
           --boot-drive=sda

###############################################################################
# PARTITIONING — LVM, NIST/CIS compliant separate mount points
###############################################################################
clearpart --all --initlabel --drives=sda
zerombr

part /boot/efi --fstype=efi   --size=512  --ondisk=sda
part /boot     --fstype=xfs   --size=1024 --ondisk=sda
part pv.01     --size=1       --grow      --ondisk=sda

volgroup vg_os pv.01

logvol /              --vgname=vg_os --fstype=xfs  --size=10240 --name=root
logvol /home          --vgname=vg_os --fstype=xfs  --size=5120  --name=home     --fsoptions="nodev"
logvol /tmp           --vgname=vg_os --fstype=xfs  --size=2048  --name=tmp      --fsoptions="nodev,nosuid,noexec"
logvol /var           --vgname=vg_os --fstype=xfs  --size=8192  --name=var      --fsoptions="nodev"
logvol /var/log       --vgname=vg_os --fstype=xfs  --size=4096  --name=var_log  --fsoptions="nodev,nosuid,noexec"
logvol /var/log/audit --vgname=vg_os --fstype=xfs  --size=2048  --name=var_audit --fsoptions="nodev,nosuid,noexec"
logvol /var/tmp       --vgname=vg_os --fstype=xfs  --size=2048  --name=var_tmp  --fsoptions="nodev,nosuid,noexec"
logvol swap           --vgname=vg_os --fstype=swap --size=4096  --name=swap

###############################################################################
# PACKAGES
###############################################################################
%packages
@^minimal-environment
@standard

# VMware integration
open-vm-tools

# AD / Entra ID join
sssd
sssd-ad
sssd-tools
realmd
adcli
oddjob
oddjob-mkhomedir
krb5-workstation
samba-common-tools

# Web console
cockpit
cockpit-system
cockpit-networkmanager
cockpit-storaged
cockpit-packagekit

# Security / hardening
audit
auditd
aide
scap-security-guide
openscap-scanner
libpwquality
firewalld
policycoreutils
policycoreutils-python-utils
setools-console

# Time sync
chrony

# Utilities
curl
wget
vim
net-tools
bind-utils
tcpdump
lsof
rsync
unzip
bash-completion
sudo

# Explicitly remove insecure packages
-telnet
-rsh
-rsh-server
-ypbind
-ypserv
-tftp
-tftp-server
-talk
-talk-server
-xinetd
-setroubleshoot
-mcstrans

%end

###############################################################################
# PRE-INSTALL SCRIPT
# Runs before installation in a minimal busybox environment.
# Used here to verify disk and log environment details.
###############################################################################
%pre --log=/tmp/ks-pre.log
#!/bin/bash
echo "=== Kickstart Pre-Install ===" >> /tmp/ks-pre.log
echo "Date: $(date)" >> /tmp/ks-pre.log
echo "Available disks:" >> /tmp/ks-pre.log
lsblk >> /tmp/ks-pre.log
%end

###############################################################################
# POST-INSTALL SCRIPT
###############################################################################
%post --log=/root/ks-post.log
#!/bin/bash
set -euo pipefail
echo "=== Kickstart Post-Install Started: $(date) ===" | tee -a /root/ks-post.log

# ---------------------------------------------------------------------------
# 1. SYSTEM UPDATE
# ---------------------------------------------------------------------------
echo "[1/13] Running system update..."
dnf update -y

# ---------------------------------------------------------------------------
# 2. SSH HARDENING (NIST AC-17, SC-8)
# ---------------------------------------------------------------------------
echo "[2/13] Hardening SSH..."
cat > /etc/ssh/sshd_config << 'EOF'
# NIST SP 800-53 hardened sshd_config
Protocol 2
Port 22
AddressFamily inet

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Authentication
PermitRootLogin no
PasswordAuthentication yes
# NOTE: Set PasswordAuthentication no after SSH keys are deployed post-clone
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Session limits
LoginGraceTime 60
MaxAuthTries 4
MaxSessions 4
ClientAliveInterval 300
ClientAliveCountMax 3

# Restrictions
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitUserEnvironment no
Banner /etc/issue.net

# Algorithms (NIST SP 800-131A compliant)
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
KexAlgorithms curve25519-sha256,ecdh-sha2-nistp521,ecdh-sha2-nistp384,diffie-hellman-group16-sha512,diffie-hellman-group14-sha256

# Logging
SyslogFacility AUTHPRIV
LogLevel VERBOSE

# Subsystems
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

chmod 600 /etc/ssh/sshd_config
systemctl enable sshd

# ---------------------------------------------------------------------------
# 3. PAM — PASSWORD POLICY & ACCOUNT LOCKOUT (NIST IA-5, AC-7)
# ---------------------------------------------------------------------------
echo "[3/13] Configuring PAM..."

# Password complexity
cat > /etc/security/pwquality.conf << 'EOF'
minlen = 15
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
maxrepeat = 3
maxclasrepeat = 4
gecoscheck = 1
dictcheck = 1
EOF

# Account lockout — 5 attempts, 15 min lockout
cat > /etc/security/faillock.conf << 'EOF'
audit
silent
deny = 5
fail_interval = 900
unlock_time = 900
even_deny_root
root_unlock_time = 900
EOF

# Password aging (NIST IA-5)
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/'  /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/'   /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/'  /etc/login.defs
sed -i 's/^UMASK.*/UMASK           027/'          /etc/login.defs

# ---------------------------------------------------------------------------
# 4. KERNEL / SYSCTL HARDENING (NIST SC-5, SC-7)
# ---------------------------------------------------------------------------
echo "[4/13] Applying sysctl hardening..."
cat > /etc/sysctl.d/99-nist-hardening.conf << 'EOF'
# === Network Hardening ===
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# === Kernel Hardening ===
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 3
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 2
kernel.core_uses_pid = 1
kernel.sysrq = 0

# === Filesystem ===
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF

sysctl -p /etc/sysctl.d/99-nist-hardening.conf

# ---------------------------------------------------------------------------
# 5. AUDITD RULES (NIST AU-2, AU-12)
# ---------------------------------------------------------------------------
echo "[5/13] Configuring auditd..."
cat > /etc/audit/rules.d/99-nist.rules << 'EOF'
## Remove all existing rules
-D

## Buffer size — increase for busy systems
-b 8192

## Failure mode: 1=log to syslog, 2=kernel panic
-f 1

## -----------------------------------------------
## Identity and authentication changes
## -----------------------------------------------
-w /etc/passwd   -p wa -k identity
-w /etc/shadow   -p wa -k identity
-w /etc/group    -p wa -k identity
-w /etc/gshadow  -p wa -k identity
-w /etc/sudoers  -p wa -k identity
-w /etc/sudoers.d/ -p wa -k identity

## -----------------------------------------------
## Login and session events
## -----------------------------------------------
-w /var/log/lastlog     -p wa -k logins
-w /var/run/faillock    -p wa -k logins
-w /var/log/tallylog    -p wa -k logins

## -----------------------------------------------
## Privilege escalation
## -----------------------------------------------
-a always,exit -F path=/usr/bin/sudo  -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/su    -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/newgrp -F perm=x -F auid>=1000 -k privileged
-a always,exit -F path=/usr/bin/chsh  -F perm=x -F auid>=1000 -k privileged
-a always,exit -F path=/usr/bin/passwd -F perm=x -F auid>=1000 -k privileged

## -----------------------------------------------
## File deletion
## -----------------------------------------------
-a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat \
   -F auid>=1000 -F auid!=4294967295 -k delete
-a always,exit -F arch=b32 -S unlink -S unlinkat -S rename -S renameat \
   -F auid>=1000 -F auid!=4294967295 -k delete

## -----------------------------------------------
## Network configuration changes
## -----------------------------------------------
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k system-locale
-w /etc/hosts            -p wa -k system-locale
-w /etc/sysconfig/network -p wa -k system-locale

## -----------------------------------------------
## System time changes (NIST AU-8)
## -----------------------------------------------
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change
-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S stime -k time-change
-a always,exit -F arch=b64 -S clock_settime -k time-change
-w /etc/localtime -p wa -k time-change

## -----------------------------------------------
## Kernel module loading
## -----------------------------------------------
-w /sbin/insmod  -p x -k modules
-w /sbin/rmmod   -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module -S delete_module -k modules

## -----------------------------------------------
## SSH configuration changes
## -----------------------------------------------
-w /etc/ssh/sshd_config -p wa -k sshd

## -----------------------------------------------
## Make rules immutable — requires reboot to change
## -----------------------------------------------
-e 2
EOF

systemctl enable auditd

# ---------------------------------------------------------------------------
# 6. CHRONY / TIME SYNC (NIST AU-8)
# ---------------------------------------------------------------------------
echo "[6/13] Configuring chrony..."
cat > /etc/chrony.conf << 'EOF'
# Primary time source — internal domain controllers
server DC01.DOMAIN.COM iburst
server DC02.DOMAIN.COM iburst

# Fallback to pool if DCs unavailable
pool pool.ntp.org iburst

driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

systemctl enable chronyd

# ---------------------------------------------------------------------------
# 7. AIDE — FILE INTEGRITY MONITORING (NIST SI-7)
# ---------------------------------------------------------------------------
echo "[7/13] Initializing AIDE..."
# Initialize database — this takes a few minutes
aide --init
mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

# Weekly integrity check via cron
cat > /etc/cron.weekly/aide-check << 'EOF'
#!/bin/bash
REPORT=/var/log/aide/aide-report-$(date +%Y%m%d).txt
mkdir -p /var/log/aide
/usr/sbin/aide --check > "$REPORT" 2>&1
# Log result to syslog
logger -t aide "Weekly integrity check completed. Report: $REPORT"
EOF
chmod 700 /etc/cron.weekly/aide-check

# ---------------------------------------------------------------------------
# 8. FIREWALL (NIST SC-7)
# ---------------------------------------------------------------------------
echo "[8/13] Configuring firewall..."
systemctl enable firewalld
systemctl start firewalld

# Default zone — drop everything not explicitly allowed
firewall-cmd --set-default-zone=drop
firewall-cmd --permanent --zone=drop --add-service=ssh
firewall-cmd --permanent --zone=drop --add-service=cockpit

# Allow Entra ID / Azure AD communication
firewall-cmd --permanent --zone=drop --add-port=443/tcp   # HTTPS to Azure
firewall-cmd --permanent --zone=drop --add-port=636/tcp   # LDAPS
firewall-cmd --permanent --zone=drop --add-port=88/tcp    # Kerberos
firewall-cmd --permanent --zone=drop --add-port=88/udp    # Kerberos
firewall-cmd --permanent --zone=drop --add-port=464/tcp   # Kerberos change
firewall-cmd --permanent --zone=drop --add-port=123/udp   # NTP

firewall-cmd --reload

# ---------------------------------------------------------------------------
# 9. LEGAL BANNER (NIST AC-8)
# ---------------------------------------------------------------------------
echo "[9/13] Setting legal banners..."
BANNER_TEXT="NOTICE: This system is for authorized use only. All activity
is monitored and recorded. Unauthorized access or use of this system
is prohibited and may be subject to criminal and civil penalties.
By continuing, you consent to monitoring."

echo "$BANNER_TEXT" > /etc/issue
echo "$BANNER_TEXT" > /etc/issue.net
echo "$BANNER_TEXT" > /etc/motd

# ---------------------------------------------------------------------------
# 10. SERVICE HARDENING (NIST CM-7)
# ---------------------------------------------------------------------------
echo "[10/13] Disabling unnecessary services..."
DISABLE_SVCS=(
    cups
    avahi-daemon
    bluetooth
    rpcbind
    nfs-server
    nfs-client.target
    rsyncd
    httpd
    postfix
)

for svc in "${DISABLE_SVCS[@]}"; do
    systemctl disable --now "$svc" 2>/dev/null || true
done

# Disable unused kernel modules
cat > /etc/modprobe.d/nist-disable.conf << 'EOF'
# NIST CM-7 — disable unused/insecure kernel modules
install cramfs   /bin/true
install freevxfs /bin/true
install jffs2    /bin/true
install hfs      /bin/true
install hfsplus  /bin/true
install squashfs /bin/true
install udf      /bin/true
install usb-storage /bin/true
install dccp     /bin/true
install sctp     /bin/true
install rds      /bin/true
install tipc     /bin/true
EOF

# ---------------------------------------------------------------------------
# 11. SUDO HARDENING (NIST AC-6)
# ---------------------------------------------------------------------------
echo "[11/13] Hardening sudo..."
cat > /etc/sudoers.d/99-nist << 'EOF'
# Require tty for sudo (NIST AC-6)
Defaults requiretty
Defaults use_pty
Defaults logfile=/var/log/sudo.log
Defaults log_input, log_output
Defaults !visiblepw
Defaults passwd_timeout=1
Defaults timestamp_timeout=5
EOF
chmod 440 /etc/sudoers.d/99-nist

# ---------------------------------------------------------------------------
# 12. COCKPIT — WEB CONSOLE (RHEL specific)
# ---------------------------------------------------------------------------
echo "[12/13] Configuring Cockpit web console..."
systemctl enable cockpit.socket

# Restrict Cockpit to use TLS only and limit origins
mkdir -p /etc/cockpit
cat > /etc/cockpit/cockpit.conf << 'EOF'
[WebService]
# Restrict to local network — update CIDR to match your environment
Origins = https://DOMAIN.COM wss://DOMAIN.COM
ProtocolHeader = X-Forwarded-Proto
LoginTitle = Authorized Access Only

[Session]
IdleTimeout = 15

[Log]
Fatal = criticals and warnings
EOF

# Cockpit uses firewalld service definition already added in step 8
# Default port is 9090
echo "Cockpit enabled on port 9090"

# ---------------------------------------------------------------------------
# 13. ENTRA ID (AZURE AD) SSSD CONFIGURATION
# NOTE: This configures sssd for Entra ID.
# The actual domain join (realm join) must happen post-clone with a valid
# service account credential. This section pre-stages the configuration.
# ---------------------------------------------------------------------------
echo "[13/13] Pre-staging Entra ID / sssd configuration..."

# Install Microsoft packages for Entra ID integration
# azure-sssd and required packages
dnf install -y \
    sssd \
    sssd-ad \
    sssd-tools \
    realmd \
    adcli \
    krb5-workstation \
    oddjob \
    oddjob-mkhomedir

# Pre-stage sssd.conf — will be completed by post-clone join script
cat > /etc/sssd/sssd.conf << 'EOF'
[sssd]
domains = DOMAIN.COM
config_file_version = 2
services = nss, pam, ssh

[domain/DOMAIN.COM]
# Entra ID / Azure AD domain
ad_domain = DOMAIN.COM
krb5_realm = DOMAIN.COM
realmd_tags = manages-system joined-with-adcli

id_provider = ad
auth_provider = ad
access_provider = ad
chpass_provider = ad

# Kerberos
krb5_store_password_if_offline = True

# Home directory and shell
default_shell = /bin/bash
fallback_homedir = /home/%u@%d
use_fully_qualified_names = True
override_homedir = /home/%u

# Group membership
ad_gpo_access_control = permissive

# Cache credentials for offline login
cache_credentials = True
krb5_ccname_template = KCM:

# Logging
debug_level = 3

[nss]
homedir_substring = /home

[pam]
offline_credentials_expiration = 7
EOF

chmod 600 /etc/sssd/sssd.conf

# Pre-stage krb5.conf
cat > /etc/krb5.conf << 'EOF'
[libdefaults]
    default_realm = DOMAIN.COM
    dns_lookup_realm = true
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    rdns = false
    noaddresses = true

[realms]
    DOMAIN.COM = {
        # Populated via DNS SRV records
    }

[domain_realm]
    .DOMAIN.COM = DOMAIN.COM
    DOMAIN.COM = DOMAIN.COM
EOF

# Enable mkhomedir — auto-creates home dirs on first AD user login
authselect select sssd with-mkhomedir with-faillock --force
systemctl enable oddjobd

# ---------------------------------------------------------------------------
# POST-CLONE DOMAIN JOIN SCRIPT
# Placed at /usr/local/sbin/entra-join.sh
# Run this script on each clone after deployment.
# ---------------------------------------------------------------------------
cat > /usr/local/sbin/entra-join.sh << 'JOINSCRIPT'
#!/bin/bash
# =============================================================================
# Post-Clone Entra ID Domain Join Script
# Run as root on each deployed VM after cloning from template.
# Usage: ./entra-join.sh
# =============================================================================
set -euo pipefail

DOMAIN="DOMAIN.COM"
TENANT_ID="TENANT-ID"
JOIN_OU="OU=Linux Servers,DC=DOMAIN,DC=COM"   # Update to your target OU

echo "=== Entra ID Domain Join ==="
echo "Domain:    $DOMAIN"
echo "Tenant ID: $TENANT_ID"
echo ""

# Prompt for join credentials
read -rp "Enter join account username (user@${DOMAIN}): " JOIN_USER
read -rsp "Enter password: " JOIN_PASS
echo ""

# Set hostname before joining
read -rp "Enter this VM's hostname (e.g. vm-linux-01): " NEW_HOSTNAME
hostnamectl set-hostname "${NEW_HOSTNAME}.${DOMAIN}"

# Verify DNS resolves domain
echo "Verifying DNS..."
if ! nslookup "$DOMAIN" > /dev/null 2>&1; then
    echo "ERROR: Cannot resolve $DOMAIN. Check DNS settings."
    exit 1
fi

# Verify time sync (Kerberos requires < 5 min skew)
echo "Verifying time sync..."
chronyc tracking | grep "System time"

# Perform domain join
echo "Joining domain $DOMAIN..."
echo "$JOIN_PASS" | realm join \
    --user="$JOIN_USER" \
    --computer-ou="$JOIN_OU" \
    --os-name="RHEL" \
    --os-version="9" \
    "$DOMAIN"

# Restart sssd
systemctl restart sssd

# Verify join
echo ""
echo "=== Join Status ==="
realm list

echo ""
echo "Domain join complete. Verify with: id <username>@${DOMAIN}"
echo "Proceed with CrowdStrike and ManageEngine agent installation."
JOINSCRIPT

chmod 750 /usr/local/sbin/entra-join.sh

# ---------------------------------------------------------------------------
# GENERALIZATION — Remove unique identifiers before template conversion
# ---------------------------------------------------------------------------
echo "=== Generalizing system for template conversion ==="

# Remove SSH host keys — regenerated on first boot of each clone
rm -f /etc/ssh/ssh_host_*

# Blank machine-id — systemd, DHCP, and journald use this
echo -n > /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# Reset hostname
hostnamectl set-hostname localhost.localdomain

# Clear bash history
history -c
cat /dev/null > /root/.bash_history
cat /dev/null > /home/localadmin/.bash_history 2>/dev/null || true

# Clear temp files
rm -rf /tmp/* /var/tmp/*

# Clear NetworkManager connection profiles (will be re-created on boot)
rm -f /etc/NetworkManager/system-connections/*

# Clear cloud-init state if present
if command -v cloud-init &>/dev/null; then
    cloud-init clean --logs
fi

echo ""
echo "=== Post-Install Complete: $(date) ==="
echo "System is ready for template conversion in vCenter."
echo ""
echo "NEXT STEPS:"
echo "  1. Shut down this VM"
echo "  2. In vCenter: right-click VM > Template > Convert to Template"
echo "  3. On each deployed clone, run: /usr/local/sbin/entra-join.sh"
echo "  4. Install CrowdStrike Falcon Sensor"
echo "  5. Install ManageEngine Endpoint Central agent"
echo "  6. Run final OpenSCAP scan to confirm compliance"

%end
