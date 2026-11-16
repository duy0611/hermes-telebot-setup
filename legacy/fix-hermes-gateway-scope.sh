#!/usr/bin/env bash
# Fix: dnguyen's `hermes` fails with "Gateway inaccessible: service_account_mismatch".
#
# Cause: /etc/systemd/system/hermes-gateway.service runs the gateway as
# hermes-telebot. Hermes's client-side runtime discovery looks up the bare unit
# name hermes-gateway.service in BOTH the user and the system scope for every
# account whose HERMES_HOME is its own ~/.hermes, and fails closed when the
# system unit's User= is not the caller. So the system unit blocks every other
# account on the box.
#
# Fix: run the bot's gateway as a user-scope unit of hermes-telebot instead
# (linger is already enabled, so it still starts at boot). The system-scope
# name is then free and dnguyen gets its own private gateway again.
#
# Run as root:   sudo bash /tmp/fix-hermes-gateway-scope.sh

set -euo pipefail

U=hermes-telebot
UH=/home/$U
UUID=$(id -u "$U")
SYS_UNIT=/etc/systemd/system/hermes-gateway.service
SYS_DROPIN=/etc/systemd/system/hermes-gateway.service.d
BACKUP=/root/hermes-gateway-system-backup
UDROP=$UH/.config/systemd/user/hermes-gateway.service.d

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run as root (sudo bash $0)" >&2
  exit 1
fi

echo "== 1/5 backup the system unit =="
install -d -m 0700 "$BACKUP"
cp -a "$SYS_UNIT" "$BACKUP/" 2>/dev/null || true
cp -a "$SYS_DROPIN" "$BACKUP/" 2>/dev/null || true
echo "   backup: $BACKUP"

echo "== 2/5 stop and remove the system-scope unit =="
systemctl disable --now hermes-gateway.service || true
rm -f "$SYS_UNIT"
rm -f "$SYS_DROPIN/10-isolation.conf"
rmdir "$SYS_DROPIN" 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed hermes-gateway.service 2>/dev/null || true

echo "== 3/5 write the user-scope hardening drop-in =="
runuser -u "$U" -- install -d -m 0700 "$UDROP"
cat > "$UDROP/10-isolation.conf" <<'EOF'
# Managed by fix-hermes-gateway-scope.sh — kept outside the unit file because
# `hermes gateway install` regenerates the unit on version changes.
#
# Directives that need CAP_SETPCAP or a private /dev are NOT usable from the
# --user manager on this host ("Failed to drop capabilities: Operation not
# permitted"), so CapabilityBoundingSet=, AmbientCapabilities=,
# PrivateDevices=, ProtectKernelModules=, ProtectKernelLogs= and ProtectClock=
# are dropped. The account is unprivileged and NoNewPrivileges=yes.
[Service]
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/hermes-telebot
InaccessiblePaths=/home/dnguyen
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
SystemCallArchitectures=native
UMask=0077
MemoryMax=8G
TasksMax=512
EOF
chown "$U:$U" "$UDROP/10-isolation.conf"
chmod 0600 "$UDROP/10-isolation.conf"

echo "== 4/5 install and start the user service as $U =="
runuser -u "$U" -- env HOME="$UH" XDG_RUNTIME_DIR="/run/user/$UUID" \
  "$UH/.local/bin/hermes" gateway install --force --start-now

echo "== 5/5 verify =="
runuser -u "$U" -- env HOME="$UH" XDG_RUNTIME_DIR="/run/user/$UUID" \
  "$UH/.local/bin/hermes" gateway ensure --json || true
runuser -u "$U" -- env HOME="$UH" XDG_RUNTIME_DIR="/run/user/$UUID" \
  systemctl --user --no-pager status hermes-gateway.service | head -20 || true

cat <<'EOF'

Done. Now, as dnguyen:

  hermes gateway ensure --json     # expect {"state": "ready", ...}
  hermes                            # should start its own private gateway

Rollback (as root) if the user unit will not start:

  cp /root/hermes-gateway-system-backup/hermes-gateway.service /etc/systemd/system/
  mkdir -p /etc/systemd/system/hermes-gateway.service.d
  cp /root/hermes-gateway-system-backup/hermes-gateway.service.d/10-isolation.conf \
     /etc/systemd/system/hermes-gateway.service.d/
  systemctl daemon-reload && systemctl enable --now hermes-gateway.service
EOF
