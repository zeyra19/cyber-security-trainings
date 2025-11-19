

#!/usr/bin/env bash
# Improved ClamAV automated install & configuration script
# - safer shell options
# - backups for config
# - removes unnecessary sudo usage
# - safer inotify handling, better checks
# - checks for required commands and systemd

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' 

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

cleanup_on_exit() {
    local rc=$?
    if [ $rc -ne 0 ]; then
        print_error "Script failed with exit code $rc"
    fi
    exit $rc
}
trap cleanup_on_exit EXIT

if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root."
    exit 1
fi

# Helper to ensure a command exists
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_error "Required command '$1' not found. Please install it first."
        exit 1
    fi
}

print_info "Starting ClamAV automated install & configuration..."

# Detect package manager (basic)
if command -v apt-get >/dev/null 2>&1; then
    PKG_INSTALL="apt-get install -y"
    PKG_UPDATE="apt-get update -y"
    export DEBIAN_FRONTEND=noninteractive
else
    print_warning "Non-debian based system detected or apt-get not found. Please install ClamAV, inotify-tools and dependencies manually."
    PKG_INSTALL=""
    PKG_UPDATE=""
fi

if [ -n "$PKG_UPDATE" ]; then
    print_info "Updating package lists..."
    $PKG_UPDATE
fi

if [ -n "$PKG_INSTALL" ]; then
    print_info "Installing required packages..."
    $PKG_INSTALL clamav clamav-daemon clamav-freshclam inotify-tools || {
        print_error "Package installation failed."
        exit 1
    }
fi

# Ensure required commands exist
require_cmd inotifywait
require_cmd clamdscan
require_cmd freshclam

print_info "Stopping ClamAV services for safe configuration..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop clamav-freshclam.service || true
    systemctl stop clamav-daemon.service || true
fi

print_info "Creating quarantine and log directories..."
mkdir -p /var/log/clamav/quarantine/realtime
mkdir -p /var/log/clamav/quarantine/daily
mkdir -p /var/log/clamav
# Quarantine should be restricted. Owned by clamav if user exists, otherwise root.
if getent passwd clamav >/dev/null 2>&1; then
    chown -R clamav:clamav /var/log/clamav /var/log/clamav/quarantine
else
    chown -R root:root /var/log/clamav
fi
chmod -R 700 /var/log/clamav/quarantine
chmod 750 /var/log/clamav

print_info "Creating realtime watch script (/usr/local/bin/clamav-watch.sh)..."
cat > /usr/local/bin/clamav-watch.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
WATCH_DIR="/home"
LOG_FILE="/var/log/clamav/clamav-watch.log"
QUARANTINE_DIR="/var/log/clamav/quarantine/realtime"
# Only act on close_write and moved_to events to avoid partial file scans
EVENTS="close_write,moved_to,create"
# Exclude common editor temp files
EXCLUDE_PATTERN='(\.swp$|~$|\.tmp$|^\.|/\.git/)'

touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

inotifywait -m -r -e close_write -e moved_to -e create --format '%w%f|%e' "$WATCH_DIR" | while IFS='|' read -r FILE EVENT; do
    # Basic exclude for temp/editor files and dotfiles
    if [[ "$FILE" =~ $EXCLUDE_PATTERN ]]; then
        echo "$(date --iso-8601=seconds) [INFO] Skipping excluded file: $FILE" >> "$LOG_FILE"
        continue
    fi

    # Only scan regular files that exist
    if [ ! -e "$FILE" ]; then
        echo "$(date --iso-8601=seconds) [WARNING] File no longer exists: $FILE" >> "$LOG_FILE"
        continue
    fi
    if [ -d "$FILE" ]; then
        echo "$(date --iso-8601=seconds) [INFO] Skipping directory: $FILE" >> "$LOG_FILE"
        continue
    fi

    echo "$(date --iso-8601=seconds): Event $EVENT on $FILE" >> "$LOG_FILE"

    # Run clamdscan; handle exit codes
    /usr/bin/clamdscan --fdpass --multiscan --move="$QUARANTINE_DIR" "$FILE" >> "$LOG_FILE" 2>&1 || rc=$? || rc=$?
    rc=${rc:-0}
    if [ "$rc" -eq 0 ]; then
        echo "$(date --iso-8601=seconds) [INFO] No virus found in: $FILE" >> "$LOG_FILE"
    elif [ "$rc" -eq 1 ]; then
        echo "$(date --iso-8601=seconds) [ALERT] Infected file moved to quarantine: $FILE" >> "$LOG_FILE"
    else
        echo "$(date --iso-8601=seconds) [ERROR] clamdscan returned code $rc for $FILE" >> "$LOG_FILE"
    fi
done
EOF

chmod 755 /usr/local/bin/clamav-watch.sh

print_info "Creating systemd service for clamav-watch (if systemd present)..."
if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/clamav-watch.service <<'EOF'
[Unit]
Description=ClamAV Watch Directory Scanner
After=network.target clamav-freshclam.service clamav-daemon.service
Requires=clamav-daemon.service

[Service]
Type=simple
ExecStart=/usr/local/bin/clamav-watch.sh
Restart=on-failure
RestartSec=5
User=root
Group=root
# Let journald handle stdout/stderr; if file logging is required the script itself appends to log
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
else
    print_warning "Systemd not found; please create a suitable service/unit for /usr/local/bin/clamav-watch.sh"
fi

print_info "Backing up existing clamd.conf (if present) and writing safer config..."
if [ -f /etc/clamav/clamd.conf ]; then
    cp -a /etc/clamav/clamd.conf /etc/clamav/clamd.conf.bak.`date +%Y%m%d%H%M%S`
fi

cat > /etc/clamav/clamd.conf <<'EOF'
#Automatically Generated by clamav-daemon postinst
#To reconfigure clamav-daemon run #dpkg-reconfigure clamav-daemon
#Please read /usr/share/doc/clamav-daemon/README.Debian.gz for details
LocalSocket /var/run/clamav/clamd.ctl
FixStaleSocket yes
LocalSocketGroup clamav
LocalSocketMode 666
# TemporaryDirectory is not set to its default /tmp here to make overriding
# the default with environment variables TMPDIR/TMP/TEMP possible
User root
ScanMail yes
ScanArchive yes
ArchiveBlockEncrypted no
MaxDirectoryRecursion 15
FollowDirectorySymlinks no
FollowFileSymlinks no
ReadTimeout 180
MaxThreads 24
MaxConnectionQueueLength 30
LogSyslog no
LogRotate yes
LogFacility LOG_LOCAL6
LogClean yes
LogVerbose no
PreludeEnable no
PreludeAnalyzerName ClamAV
DatabaseDirectory /var/lib/clamav
OfficialDatabaseOnly no
SelfCheck 3600
Foreground no
Debug no
ScanPE yes
MaxEmbeddedPE 10M
ScanOLE2 yes
ScanPDF yes
ScanHTML yes
MaxHTMLNormalize 10M
MaxHTMLNoTags 2M
MaxScriptNormalize 5M
MaxZipTypeRcg 1M
ScanSWF yes
ExitOnOOM no
LeaveTemporaryFiles no
AlgorithmicDetection yes
ScanELF yes
IdleTimeout 30
CrossFilesystems yes
PhishingSignatures yes
PhishingScanURLs yes
PhishingAlwaysBlockSSLMismatch no
PhishingAlwaysBlockCloak no
PartitionIntersection no
DetectPUA no
ScanPartialMessages no
HeuristicScanPrecedence no
StructuredDataDetection no
CommandReadTimeout 30
SendBufTimeout 200
MaxQueue 100
ExtendedDetectionInfo yes
OLE2BlockMacros no
AllowAllMatchScan yes
ForceToDisk no
DisableCertCheck no
DisableCache no
MaxScanTime 120000
MaxScanSize 2G
MaxFileSize 2G
MaxRecursion 25
MaxFiles 10000
MaxPartitions 50
MaxIconsPE 100
PCREMatchLimit 10000
PCRERecMatchLimit 5000
PCREMaxFileSize 25M
ScanXMLDOCS yes
ScanHWP3 yes
MaxRecHWP3 16
StreamMaxLength 2G
LogFile /var/log/clamav/clamav.log
LogTime yes
LogFileUnlock no
LogFileMaxSize 0
Bytecode yes
BytecodeSecurity TrustSigned
BytecodeTimeout 60000
OnAccessMaxFileSize 5M
EOF

# Ensure clamav user/group exist and fix ownerships
if getent passwd clamav >/dev/null 2>&1; then
    chown -R clamav:clamav /var/lib/clamav /var/log/clamav
else
    print_warning "clamav user not present on system. Ensure clamd runs under an unprivileged user."
fi

print_info "Creating daily full-scan script (/usr/local/bin/clamav-fullscan.sh)..."
cat > /usr/local/bin/clamav-fullscan.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCAN_DIR="/home"
QUARANTINE_DIR="/var/log/clamav/quarantine/daily"
LOG_FILE="/var/log/clamav/clamav-viruses.log"

mkdir -p "$QUARANTINE_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Run clamdscan; capture exit code and output
OUTPUT=$(/usr/bin/clamdscan --fdpass --multiscan --move="$QUARANTINE_DIR" "$SCAN_DIR" 2>&1) || rc=$?
rc=${rc:-0}
echo "$(date --iso-8601=seconds) Full scan exit code: $rc" >> "$LOG_FILE"
echo "$OUTPUT" >> "$LOG_FILE"

if [ "$rc" -eq 1 ]; then
    echo "$(date --iso-8601=seconds) Infected files were found and (if possible) moved to $QUARANTINE_DIR" >> "$LOG_FILE"
elif [ "$rc" -eq 0 ]; then
    echo "$(date --iso-8601=seconds) No infected files found." >> "$LOG_FILE"
else
    echo "$(date --iso-8601=seconds) An error occurred during scan (exit code $rc)." >> "$LOG_FILE"
fi
EOF

chmod 755 /usr/local/bin/clamav-fullscan.sh

print_info "Creating logrotate config (/etc/logrotate.d/clamav-watch)..."
cat > /etc/logrotate.d/clamav-watch <<'EOF'
/var/log/clamav/clamav-watch.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 640 root adm
}

/var/log/clamav/clamav-viruses.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 640 root adm
}

/var/log/clamav/clamav.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    create 640 clamav adm
}
EOF

print_info "Installing cron job for daily full scan at 15:00..."
CRON_ENTRY="0 15 * * * /usr/local/bin/clamav-fullscan.sh"
# Safer cron addition: only add if not present
( crontab -l 2>/dev/null | grep -F "$CRON_ENTRY" >/dev/null 2>&1 ) || ( crontab -l 2>/dev/null; echo "$CRON_ENTRY" ) | crontab -

print_info "Updating ClamAV database (freshclam)..."
# Run freshclam and retry once if it fails
if ! freshclam; then
    print_warning "freshclam failed once, retrying after a short wait..."
    sleep 5
    freshclam || print_warning "freshclam failed again; please investigate network or repository issues."
fi

print_info "Starting and enabling ClamAV services (systemd)..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now clamav-freshclam.service || print_warning "Could not enable/start clamav-freshclam.service"
    systemctl enable --now clamav-daemon.service || print_warning "Could not enable/start clamav-daemon.service"
    systemctl enable --now clamav-watch.service || print_warning "Could not enable/start clamav-watch.service"
else
    print_warning "Systemd not detected; please enable/start clamav services manually."
fi

print_info "Final ownership/permission adjustments..."
if getent passwd clamav >/dev/null 2>&1; then
    chown -R clamav:clamav /var/lib/clamav
    chown -R clamav:clamav /var/log/clamav
fi

print_info "ClamAV installation & configuration complete. Please review /etc/clamav/clamd.conf.bak* and /etc/clamav/clamd.conf before production use.
