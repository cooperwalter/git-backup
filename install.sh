#!/bin/bash
# Installs (or reinstalls) the launchd agent that runs git-backup.sh daily at 02:00.
set -eu

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SRC="$SELF_DIR/com.git-backup.agent.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.git-backup.agent.plist"

# Dedicated bash copy: macOS TCC blocks launchd-spawned /bin/bash from iCloud
# Drive. Granting Full Disk Access to this one binary (not /bin/bash globally)
# scopes the permission to this agent alone.
RUNNER="$SELF_DIR/bin/git-backup-bash"
if [ ! -x "$RUNNER" ]; then
  mkdir -p "$SELF_DIR/bin"
  cp /bin/bash "$RUNNER"
  # a copied system binary loses platform trust and is killed by the kernel
  # (OS_REASON_CODESIGNING) unless re-signed ad hoc
  codesign -s - -f "$RUNNER"
fi

mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__INSTALL_DIR__|$SELF_DIR|g" -e "s|__HOME__|$HOME|g" \
    "$PLIST_SRC" > "$PLIST_DST"
launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

echo "Installed: runs daily at 02:00 (or on next wake after a missed run)."
echo "Run now:   launchctl kickstart gui/$(id -u)/com.git-backup.agent"
echo "Log:       ~/Library/Logs/git-backup.log"
echo ""
echo "ONE-TIME SETUP — without this, scheduled runs cannot reach iCloud Drive:"
echo "  System Settings → Privacy & Security → Full Disk Access → '+' →"
echo "  add: $RUNNER"
