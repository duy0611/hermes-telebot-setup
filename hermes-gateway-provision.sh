#!/usr/bin/env bash
# hermes-gateway-provision.sh — provision ONE isolated Telegram gateway account.
#
#   sudo bash hermes-gateway-provision.sh hermes-telebot        # first account
#   sudo bash hermes-gateway-provision.sh hermes-telebot-wife   # another one
#   sudo bash hermes-gateway-provision.sh hermes-telebot --verify
#   bash hermes-gateway-provision.sh hermes-telebot-wife --dry-run
#   bash hermes-gateway-provision.sh hermes-telebot-wife --init-config
#
# Idempotent: every step re-checks before acting, so a re-run is safe.
# Supersedes hermes-telebot-provision.sh + fix-hermes-gateway-scope.sh (see legacy/).
#
# Getting the bot token and the allowed user IDs (they are different numbers):
#   see README.md → "Getting the bot token and the allowed IDs".
#
# Options:
#   --config FILE            per-account config (default accounts/<account>.env)
#   --init-config            write a commented template and exit
#   --dry-run                resolve inputs, print the plan, change nothing
#   --verify                 run only the acceptance tests against a live account
#   --reuse-operator-token   allow reusing the operator's bot token (stops their gateway)
#   --force-env              overwrite a live .env token with the configured one
#   --allow-degraded         on start failure, retry without ProtectHome (weaker)
#   --operator USER          override operator detection (default: SUDO_USER)
#   --operator-home PATH     override the operator's home directory
#   --model-from ACCOUNT     inherit LITELLM_* from another account's .env
#                            (default: hermes-telebot; "none" to disable)
#   --defer-telegram         provision the account, sandbox and unit, but leave
#                            the gateway disabled until a bot token exists;
#                            re-run without the flag once it does
#
# ── Why the sandbox lives in a USER unit, not a system unit ──────────────────
# An earlier version installed /etc/systemd/system/hermes-gateway.service with
# User=hermes-telebot. Hermes' client-side runtime discovery looks up the bare
# unit name hermes-gateway.service in BOTH scopes for every account, and fails
# closed with `service_account_mismatch` when the system unit's User= is not the
# caller. A system unit is a host-wide singleton, so it blocks every other
# account on the box and cannot be used for a per-account fleet.
#
# Each account now runs its own USER unit with `loginctl enable-linger`, so the
# unit lives in /home/<account>/.config/systemd/user/, inside that account's
# private user manager. Names never collide between accounts, other accounts
# keep working, and the gateway still starts at boot with nobody logged in.
#
# ── Why the hardening lives in a DROP-IN ────────────────────────────────────
# `hermes gateway install` regenerates the unit file when the installed version
# changes, which would erase inline hardening. Drop-ins in
# <unit>.service.d/ survive regeneration.
#
# ── Directives that must NOT go in a --user unit ────────────────────────────
# CapabilityBoundingSet=, AmbientCapabilities=, PrivateDevices=,
# ProtectKernelModules=, ProtectKernelLogs= and ProtectClock= fail under the
# --user manager on this host ("Failed to drop capabilities: Operation not
# permitted") and abort the start. The account is unprivileged and
# NoNewPrivileges=yes, so their absence does not weaken the containment.
#
# Writes, next to this script:
#   provision-<account>.log (or verify-<account>.log)  transcript
#   rollback-<account>.md                              rollback + teardown notes
#
# Reads, first hit wins per key:
#   --config FILE
#   accounts/<account>.env         TELEGRAM_* + LITELLM_* (see --init-config)
#   <account>.secrets              legacy per-account file (LITELLM_* only)
#   <account>/.hermes/.env         the live config, on a re-run
#   operator .env                  TELEGRAM_* only, and only with --reuse-operator-token

set -Eeuo pipefail

umask 022

# ---------------------------------------------------------------- parameters
ACCOUNT=""
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OPERATOR=""; OPERATOR_HOME=""
CONFIG=""; REUSE_TOKEN=0; FORCE_ENV=0; ALLOW_DEGRADED=0
DRY_RUN=0; VERIFY_ONLY=0; INIT_CONFIG=0; MODEL_FROM="hermes-telebot"; DEFER_TELEGRAM=0

while [ $# -gt 0 ]; do
  case "$1" in
    --operator)              OPERATOR="${2:?--operator needs a value}"; shift 2 ;;
    --operator-home)         OPERATOR_HOME="${2:?--operator-home needs a value}"; shift 2 ;;
    --config)                CONFIG="${2:?--config needs a value}"; shift 2 ;;
    --model-from)            MODEL_FROM="${2:?--model-from needs a value}"; shift 2 ;;
    --defer-telegram|--no-telegram) DEFER_TELEGRAM=1; shift ;;
    --reuse-operator-token)  REUSE_TOKEN=1; shift ;;
    --force-env)             FORCE_ENV=1; shift ;;
    --allow-degraded)        ALLOW_DEGRADED=1; shift ;;
    --dry-run)               DRY_RUN=1; shift ;;
    --verify)                VERIFY_ONLY=1; shift ;;
    --init-config)           INIT_CONFIG=1; shift ;;
    -h|--help)               awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    -*)                      printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
    *)
      if [ -n "$ACCOUNT" ]; then
        printf 'unexpected argument: %s (account already set to %s)\n' "$1" "$ACCOUNT" >&2; exit 2
      fi
      ACCOUNT="$1"; shift ;;
  esac
done
ACCOUNT="${ACCOUNT:-hermes-telebot}"

[[ "$ACCOUNT" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
  || { printf 'invalid account name: %s\n' "$ACCOUNT" >&2; exit 2; }

SVC="$ACCOUNT"
SVC_HOME="/home/$SVC"
SVC_HERMES="$SVC_HOME/.hermes"
if [ "$VERIFY_ONLY" -eq 1 ]; then
  LOG="$SCRIPT_DIR/verify-$SVC.log"
else
  LOG="$SCRIPT_DIR/provision-$SVC.log"
fi
ROLLBACK="$SCRIPT_DIR/rollback-$SVC.md"

PASS=0; FAIL=0; WARN=0

# ------------------------------------------------------------------- helpers
say()  { printf '\n== %s ==\n' "$*"; }
log()  { printf '   %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*"; WARN=$((WARN+1)); }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

mask() { [ -n "$1" ] || { printf '(empty)'; return 0; }
         printf '%s…%s' "${1:0:6}" "${1: -4}"; }

check() {  # check <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '   PASS  %s\n' "$label"; PASS=$((PASS+1))
  else
    printf '   FAIL  %s\n' "$label"; FAIL=$((FAIL+1))
  fi
}

check_neg() {  # check_neg <label> <command...> — PASS when the command fails
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '   FAIL  %s\n' "$label"; FAIL=$((FAIL+1))
  else
    printf '   PASS  %s\n' "$label"; PASS=$((PASS+1))
  fi
}

open_log() {
  if [ "$DRY_RUN" -eq 0 ]; then
    : > "$LOG"
  else
    printf '\n--- dry run %s ---\n' "$(date -Is)" >> "$LOG"
  fi
  if id "$OPERATOR" >/dev/null 2>&1; then
    chown "$OPERATOR:" "$LOG" 2>/dev/null || true
  fi
  exec > >(tee -a "$LOG") 2>&1
  # Close our copy of the pipe so tee sees EOF and flushes before exit.
  trap 'exec 1>&- 2>&-; wait 2>/dev/null || true' EXIT
}

as_svc() {
  runuser -u "$SVC" -- env HOME="$SVC_HOME" USER="$SVC" LOGNAME="$SVC" \
    HERMES_HOME="$SVC_HERMES" \
    PATH="$SVC_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}

svc_systemctl() {
  as_svc env XDG_RUNTIME_DIR="/run/user/$SVC_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SVC_UID/bus" \
    systemctl --user --no-pager "$@"
}

svc_hermes() {
  local bin=""
  for bin in "$SVC_HOME/.local/bin/hermes" \
             "$SVC_HERMES/hermes-agent/.hermes/bin/hermes"; do
    if [ -x "$bin" ]; then break; fi
    bin=""
  done
  [ -n "$bin" ] || die "no hermes launcher for $SVC (provision it first, or check the install)"
  as_svc "$bin" "$@"
}

UNIT_NAME="hermes-gateway"
UNIT_DIR="$SVC_HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/$UNIT_NAME.service"
DROPIN_DIR="$UNIT_FILE.d"
DROPIN="$DROPIN_DIR/10-isolation.conf"

wait_active() {  # wait_active <seconds>
  local i
  for i in $(seq 1 "${1:-30}"); do
    if [ "$(svc_systemctl is-active "$UNIT_NAME" 2>/dev/null)" = active ]; then return 0; fi
    sleep 2
  done
  [ "$(svc_systemctl is-active "$UNIT_NAME" 2>/dev/null)" = active ]
}

main_pid() { svc_systemctl show -p MainPID --value "$UNIT_NAME" 2>/dev/null || true; }

unit_enabled()  { [ "$(svc_systemctl is-enabled "$UNIT_NAME" 2>/dev/null)" = enabled ]; }
unit_prop()     { svc_systemctl show "$UNIT_NAME" -p "$1" --value 2>/dev/null; }

# ------------------------------------------------------------------ template
write_config_template() {
  local p="$1"
  cat > "$p" <<'EOF'
# hermes-gateway-provision.sh — per-account config. Mode 0600, never commit.
#
# Telegram: create a NEW bot per account with @BotFather (/newbot). Two
# accounts polling one token fight over getUpdates (409, dropped messages), so
# a distinct token is required unless you pass --reuse-operator-token for a
# one-off migration of the operator's existing bot.
#
#   token: @BotFather → /newbot → display name → username ending in "bot"
#   ids:   numeric user IDs, NOT usernames. Message @userinfobot from the
#          account that should be allowed; it replies with e.g. 1590306400.
#          Comma-separate several people. Details: README.md.
#
# TELEGRAM_HOME_CHANNEL is the DM chat id — for a DM that is the same number as
# the person's user ID, so you can leave it blank.
TELEGRAM_BOT_TOKEN=
TELEGRAM_ALLOWED_USERS=
TELEGRAM_HOME_CHANNEL=

# Model endpoint (LiteLLM virtual key). Omit to keep whatever the account's
# config.yaml already has.
LITELLM_BASE_URL=
LITELLM_API_KEY=
LITELLM_MODEL=

# Optional overrides; LITELLM_* above implies provider=litellm + model=LITELLM_MODEL.
# MODEL_PROVIDER=litellm
# MODEL_DEFAULT=cloud.deepseek-v4.1-flash
# APPROVALS_MODE=smart
EOF
  chmod 600 "$p"
  if id "$OPERATOR" >/dev/null 2>&1; then
    chown "$OPERATOR:" "$p" 2>/dev/null || true
  fi
}

if [ "$INIT_CONFIG" -eq 1 ]; then
  [ -n "$OPERATOR" ] || OPERATOR="${SUDO_USER:-$(id -un)}"
  target="$SCRIPT_DIR/accounts/$SVC.env"
  [ -n "$CONFIG" ] && target="$CONFIG"
  [ -e "$target" ] && { printf 'exists, not overwriting: %s\n' "$target" >&2; exit 1; }
  mkdir -p "$(dirname "$target")"
  write_config_template "$target"
  printf 'wrote %s (mode 600)\n' "$target"
  printf 'fill in TELEGRAM_BOT_TOKEN + TELEGRAM_ALLOWED_USERS, then:\n'
  printf '  sudo bash %s %s\n' "$0" "$SVC"
  exit 0
fi

# --------------------------------------------------------------- pre-flight
say "pre-flight ($SVC)"

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  die "must run as root: sudo bash $0 $SVC"
fi

# Operator: the human who owns this checkout / the source .env.
if [ -z "$OPERATOR" ]; then
  OPERATOR="${SUDO_USER:-}"
  if [ -z "$OPERATOR" ] || [ "$OPERATOR" = root ]; then
    OPERATOR="$(stat -c %U "$SCRIPT_DIR")"
  fi
fi
id "$OPERATOR" >/dev/null 2>&1 || die "unknown operator account: $OPERATOR"
[ -n "$OPERATOR_HOME" ] || OPERATOR_HOME="$(getent passwd "$OPERATOR" | cut -d: -f6)"
[ -n "$OPERATOR_HOME" ] || die "cannot resolve home directory for $OPERATOR"
[ -d "$OPERATOR_HOME" ] || die "operator home does not exist: $OPERATOR_HOME"
OP_ENV="$OPERATOR_HOME/.hermes/.env"

# Account data sources, first hit wins per key.
[ -n "$CONFIG" ] || CONFIG="$SCRIPT_DIR/accounts/$SVC.env"
LEGACY_SECRETS="$SCRIPT_DIR/$SVC.secrets"
LIVE_ENV="$SVC_HERMES/.env"

read_kv() {  # read_kv <file> <key> — parse, never source
  local f="$1" k="$2" v=""
  [ -r "$f" ] || return 0
  v="$(grep -m1 "^${k}=" "$f" 2>/dev/null | cut -d= -f2- || true)"
  v="${v%$'\r'}"
  v="${v%\"}"; v="${v#\"}"
  v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

value() {  # value <key> [allow-operator-fallback]
  local key="$1" op_fallback="${2:-0}" f="" v=""
  for f in "$CONFIG" "$LEGACY_SECRETS" "$LIVE_ENV"; do
    v="$(read_kv "$f" "$key")"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  if [ "$op_fallback" -eq 1 ] && [ "$REUSE_TOKEN" -eq 1 ]; then
    v="$(read_kv "$OP_ENV" "$key")"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  fi
}

TOKEN="$(value TELEGRAM_BOT_TOKEN 1)"
RAW_ALLOWED="$(value TELEGRAM_ALLOWED_USERS 1)"
HOME_CHANNEL="$(value TELEGRAM_HOME_CHANNEL 1)"
LITELLM_BASE_URL="$(value LITELLM_BASE_URL)"
LITELLM_API_KEY="$(value LITELLM_API_KEY)"
LITELLM_MODEL="$(value LITELLM_MODEL)"
MODEL_PROVIDER="$(value MODEL_PROVIDER)"
MODEL_DEFAULT="$(value MODEL_DEFAULT)"
APPROVALS_MODE="$(value APPROVALS_MODE)"
[ -n "$APPROVALS_MODE" ] || APPROVALS_MODE=smart

# A new account with no model config would come up with no provider at all.
# "Same setup as <account>" means inheriting that account's working LiteLLM
# endpoint unless the caller says --model-from none.
MODEL_SOURCE=""
if [ -z "$LITELLM_MODEL" ] && [ -n "$MODEL_FROM" ] && [ "$MODEL_FROM" != none ] \
   && [ "$MODEL_FROM" != "$SVC" ] && [ -r "/home/$MODEL_FROM/.hermes/.env" ]; then
  LITELLM_BASE_URL="$(read_kv "/home/$MODEL_FROM/.hermes/.env" LITELLM_BASE_URL)"
  LITELLM_API_KEY="$(read_kv "/home/$MODEL_FROM/.hermes/.env" LITELLM_API_KEY)"
  LITELLM_MODEL="$(read_kv "/home/$MODEL_FROM/.hermes/.env" LITELLM_MODEL)"
  if [ -n "$LITELLM_MODEL" ]; then MODEL_SOURCE="$MODEL_FROM/.hermes/.env"; fi
fi

if [ -z "$MODEL_PROVIDER" ] && [ -n "$LITELLM_MODEL" ]; then MODEL_PROVIDER=litellm; fi
if [ -z "$MODEL_DEFAULT" ] && [ -n "$LITELLM_MODEL" ]; then MODEL_DEFAULT="$LITELLM_MODEL"; fi

ALLOWED="$(printf '%s' "$RAW_ALLOWED" | tr ',' '\n' | tr -d ' ' \
             | grep -E '^[0-9]+$' | paste -sd, - || true)"
if [ -z "$HOME_CHANNEL" ]; then
  HOME_CHANNEL="$(printf '%s' "$ALLOWED" | cut -d, -f1)"
fi

if [ "$VERIFY_ONLY" -eq 0 ] && [ "$DEFER_TELEGRAM" -eq 0 ]; then
  [ -n "$TOKEN" ] || die "no TELEGRAM_BOT_TOKEN in $CONFIG, $LEGACY_SECRETS or $LIVE_ENV
       (or pass --reuse-operator-token to inherit the operator's bot,
        or --defer-telegram to provision now and add the token later)"
  [ -n "$ALLOWED" ] || die "no numeric IDs in TELEGRAM_ALLOWED_USERS (${RAW_ALLOWED:-(empty)})"
  if [ "$ALLOWED" != "$RAW_ALLOWED" ]; then
    warn "TELEGRAM_ALLOWED_USERS had non-numeric entries; keeping only: $ALLOWED (was: $RAW_ALLOWED)"
  fi
fi

if [ "$DEFER_TELEGRAM" -eq 1 ]; then
  warn "telegram deferred: the unit will be installed but left disabled and stopped"
  if [ -z "$TOKEN" ]; then
    warn "  no bot token found — the gateway cannot run until you add one"
  fi
fi

# Telegram contention: one token may only have one consumer.
OP_TOKEN="$(read_kv "$OP_ENV" TELEGRAM_BOT_TOKEN)"
TOKEN_OWNER=""
if [ -n "$TOKEN" ] && [ "$TOKEN" = "$OP_TOKEN" ] && [ "$SVC" != "$OPERATOR" ]; then
  TOKEN_OWNER="$OPERATOR"
fi
for d in /home/*; do
  b="$(basename "$d")"
  [ "$b" = "$SVC" ] && continue
  case "$b" in hermes-*) ;; *) continue ;; esac
  if [ -n "$TOKEN" ] && [ -r "$d/.hermes/.env" ] \
     && [ "$(read_kv "$d/.hermes/.env" TELEGRAM_BOT_TOKEN)" = "$TOKEN" ]; then
    die "token already in use by $b ($d/.hermes/.env) — create a separate bot with @BotFather"
  fi
done
if [ -n "$TOKEN_OWNER" ] && [ "$REUSE_TOKEN" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
  die "TELEGRAM_BOT_TOKEN is $OPERATOR's token.
       Create a new bot with @BotFather, or pass --reuse-operator-token to
       migrate it (that STOPS $OPERATOR's gateway, since two pollers on one
       token corrupt the getUpdates offset)."
fi

if [ "$VERIFY_ONLY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  AVAIL_KB="$(df --output=avail /home | tail -1 | tr -d ' ')"
  [ "$AVAIL_KB" -gt 3145728 ] || die "need >3 GB free on /home (have $((AVAIL_KB/1024)) MB)"
  for c in runuser useradd loginctl systemctl nsenter setpriv findmnt tee; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
fi

# A system-scope gateway unit is a host-wide singleton: Hermes matches the bare
# unit name for every account and fails closed when User= is not the caller.
for f in /etc/systemd/system/hermes-gateway*.service; do
  [ -e "$f" ] || continue
  warn "$f exists — a system-scope gateway unit blocks every other account"
  warn "  (service_account_mismatch). Remove it: see legacy/fix-hermes-gateway-scope.sh"
done

open_log

if [ "$VERIFY_ONLY" -eq 0 ]; then
  log "account       : $SVC"
  log "account home  : $SVC_HOME  (HERMES_HOME: $SVC_HERMES)"
  log "operator      : $OPERATOR <$OPERATOR_HOME>"
  log "config source : $([ -r "$CONFIG" ] && printf '%s' "$CONFIG" || printf '(none)')"
  log "legacy/secret : $(for f in "$CONFIG" "$LEGACY_SECRETS" "$LIVE_ENV"; do [ -r "$f" ] && printf '%s ' "$f"; done)"
  log "allowed users : ${ALLOWED:-(unresolved)}"
  log "home channel  : ${HOME_CHANNEL:-(unresolved)}"
  log "bot token     : $(mask "$TOKEN")"
  log "model         : ${MODEL_PROVIDER:-<unchanged>} / ${MODEL_DEFAULT:-<unchanged>}${MODEL_SOURCE:+  (inherited from $MODEL_SOURCE)}"
  if [ -n "$TOKEN_OWNER" ]; then
    log "contention    : reusing $TOKEN_OWNER's token — their gateway will be stopped"
  fi
  if [ "$(id -u)" -ne 0 ]; then
    warn "dry run as a non-root user: unreadable files are reported as empty"
  fi
else
  log "verify-only run for $SVC"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  say "dry run — nothing changed"
  log "would: create $SVC (useradd, 0700 home) unless it exists"
  log "would: install hermes as $SVC if no launcher is present"
  if [ "$DEFER_TELEGRAM" -eq 1 ]; then
    log "would: write $LIVE_ENV (0600) without TELEGRAM_* (deferred) plus the model keys"
  else
    log "would: write $LIVE_ENV (0600) with TELEGRAM_* and the model keys"
  fi
  log "would: loginctl enable-linger $SVC, install user unit $UNIT_NAME"
  log "would: write $DROPIN"
  if [ "$DEFER_TELEGRAM" -eq 1 ]; then
    log "would: install the user unit and leave it DISABLED (--defer-telegram)"
  else
    log "would: start the gateway and confirm it is active"
  fi
  log "would: run the acceptance tests"
  exit 0
fi

# ---------------------------------------------------------------------------
if [ "$VERIFY_ONLY" -eq 0 ]; then

  # ------------------------------------------------------- 1. the account
  say "1/9 account $SVC"
  if id "$SVC" >/dev/null 2>&1; then
    log "already exists"
  else
    useradd --create-home --shell /bin/bash --comment "Hermes gateway (sandboxed)" "$SVC"
    log "created"
  fi
  passwd --lock "$SVC" >/dev/null 2>&1 || true
  GRP_LIST="$(id -nG "$SVC")"
  log "groups: $GRP_LIST"
  if printf '%s' "$GRP_LIST" | tr ' ' '\n' \
       | grep -Eqx 'sudo|wheel|docker|adm|lpadmin|ollama|systemd-journal'; then
    die "$SVC has a privileged group; aborting before any further change"
  fi
  SVC_UID="$(id -u "$SVC")"
  SVC_GID="$(id -g "$SVC")"
  chmod 0700 "$SVC_HOME"
  install -d -o "$SVC" -g "$SVC" -m 0700 "$SVC_HERMES" "$SVC_HOME/projects"

  # ---------------------------------------------------- 2. install hermes
  say "2/9 hermes install"
  if [ -x "$SVC_HOME/.local/bin/hermes" ] \
     || [ -x "$SVC_HERMES/hermes-agent/.hermes/bin/hermes" ]; then
    log "already installed"
  else
    log "running the upstream installer as $SVC (minutes: python, node, chromium)"
    runuser -u "$SVC" -- env HOME="$SVC_HOME" HERMES_HOME="$SVC_HERMES" \
      bash -lc 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
                | bash -s -- --non-interactive --skip-computer-use'
  fi
  chown -R "$SVC:$SVC" "$SVC_HOME"
  svc_hermes --version

  # ------------------------------------------------------ 3. minimal .env
  say "3/9 minimal .env"
  TMP_ENV="$(mktemp)"; chmod 600 "$TMP_ENV"
  {
    printf '# Hermes gateway (%s) — minimal credential set; do not add unrelated keys\n' "$SVC"
    if [ -n "$TOKEN" ]; then
      printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN"
      [ -n "$ALLOWED" ]      && printf 'TELEGRAM_ALLOWED_USERS=%s\n' "$ALLOWED"
      [ -n "$HOME_CHANNEL" ] && printf 'TELEGRAM_HOME_CHANNEL=%s\n' "$HOME_CHANNEL"
    else
      printf '# TELEGRAM_BOT_TOKEN= (pending) — add it and re-run without --defer-telegram\n'
    fi
    if [ -n "$LITELLM_API_KEY" ];  then printf 'LITELLM_API_KEY=%s\n'  "$LITELLM_API_KEY";  fi
    if [ -n "$LITELLM_BASE_URL" ]; then printf 'LITELLM_BASE_URL=%s\n' "$LITELLM_BASE_URL"; fi
    if [ -n "$LITELLM_MODEL" ];    then printf 'LITELLM_MODEL=%s\n'    "$LITELLM_MODEL";    fi
  } > "$TMP_ENV"

  if [ -r "$LIVE_ENV" ]; then
    # Keep extra keys the operator added by hand; never silently drop them.
    while IFS= read -r line; do
      case "$line" in ''|\#*) continue ;; esac
      k="${line%%=*}"
      if ! grep -q "^${k}=" "$TMP_ENV"; then printf '%s\n' "$line" >> "$TMP_ENV"; fi
    done < "$LIVE_ENV"

    old_token="$(read_kv "$LIVE_ENV" TELEGRAM_BOT_TOKEN)"
    if [ -n "$old_token" ] && [ "$old_token" != "$TOKEN" ]; then
      if [ "$FORCE_ENV" -eq 1 ]; then
        warn "live .env token differs — replacing it with the configured one (--force-env)"
      else
        warn "live .env token differs — KEEPING the live token; pass --force-env to replace it"
        sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=$old_token|" "$TMP_ENV"
        TOKEN="$old_token"
      fi
    fi
  fi

  install -o "$SVC" -g "$SVC" -m 0600 "$TMP_ENV" "$LIVE_ENV"
  rm -f "$TMP_ENV"
  log "wrote $LIVE_ENV (0600 $SVC:$SVC)"

  # ----------------------------------------------------- 4. model config
  say "4/9 model configuration"
  if [ -n "$MODEL_PROVIDER" ] && [ -n "$MODEL_DEFAULT" ]; then
    if [ -n "$LITELLM_BASE_URL" ]; then
      svc_hermes config set --force providers.litellm.base_url "$LITELLM_BASE_URL" || true
      svc_hermes config set --force providers.litellm.key_env  LITELLM_API_KEY      || true
    fi
    svc_hermes config set --force model.provider "$MODEL_PROVIDER" || true
    svc_hermes config set --force model.default  "$MODEL_DEFAULT"  || true
  else
    warn "no LITELLM_* / MODEL_* in any config source — model left unchanged"
  fi
  svc_hermes config set --force approvals.mode "$APPROVALS_MODE" || true
  chown -R "$SVC:$SVC" "$SVC_HERMES"

  # ------------------------------------- 5. linger + user manager ready
  say "5/9 user manager (linger)"
  loginctl enable-linger "$SVC" >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    if [ -S "/run/user/$SVC_UID/bus" ]; then break; fi
    sleep 1
  done
  [ -S "/run/user/$SVC_UID/bus" ] || die "user manager bus never appeared at /run/user/$SVC_UID/bus"
  log "linger=$(loginctl show-user "$SVC" -p Linger --value 2>/dev/null || true) bus=ok"

  # ------------------------------------------------------- 6. user unit
  say "6/9 user-scope unit"
  # Installed as the account itself: HERMES_HOME is then that account's native
  # default, so Hermes picks the bare unit name. Installing from root would hash
  # it into hermes-gateway-<hash>.service.
  INSTALL_ARGS=(--force --force-unit-path --no-start-now)
  if [ "$DEFER_TELEGRAM" -eq 0 ]; then
    INSTALL_ARGS+=(--start-on-login)
  else
    # A unit enabled at boot without a bot token would crash-loop.
    INSTALL_ARGS+=(--no-start-on-login)
  fi
  svc_hermes gateway install "${INSTALL_ARGS[@]}"
  [ -f "$UNIT_FILE" ] \
    || die "expected $UNIT_FILE; found: $(ls -1 "$UNIT_DIR" 2>/dev/null | tr '\n' ' ')"
  log "unit: $UNIT_FILE"

  # ---------------------------------------------------------- 7. drop-in
  say "7/9 sandbox drop-in"
  install -d -o "$SVC" -g "$SVC" -m 0700 "$DROPIN_DIR"

  INACC=()
  if [ "$OPERATOR_HOME" != "$SVC_HOME" ]; then INACC+=("$OPERATOR_HOME"); fi
  for d in /home/*; do
    b="$(basename "$d")"
    if [ "$b" = "$SVC" ]; then continue; fi
    case "$b" in hermes-*) INACC+=("$d") ;; esac
  done
  INACC_LINE=""
  for p in "${INACC[@]}"; do
    case "$p" in *" "*) warn "skipping InaccessiblePaths entry with a space: $p"; continue ;; esac
    INACC_LINE="${INACC_LINE:+$INACC_LINE }$p"
  done

  DROPIN_INACC=""
  if [ -n "$INACC_LINE" ]; then DROPIN_INACC="InaccessiblePaths=$INACC_LINE"; fi

  cat > "$DROPIN" <<EOF
# Managed by hermes-gateway-provision.sh ($(date -Is)) — do NOT inline these
# into the unit: \`hermes gateway install\` regenerates it on version changes.
#
# User-scope only. CapabilityBoundingSet=, AmbientCapabilities=,
# PrivateDevices=, ProtectKernelModules=, ProtectKernelLogs= and ProtectClock=
# cannot be applied by the --user manager here and abort the start.
[Service]
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$SVC_HOME
$DROPIN_INACC
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
  chown "$SVC:$SVC" "$DROPIN"
  chmod 0600 "$DROPIN"
  log "wrote $DROPIN"
  log "inaccessible: ${INACC_LINE:-(none)}"
  svc_systemctl daemon-reload

  # -------------------------------------------- 8. token flip, then start
  say "8/9 start"
  if [ "$DEFER_TELEGRAM" -eq 1 ]; then
    svc_systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
    svc_systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true
    log "telegram deferred — unit is installed, but not enabled and not running"
    log "finish later: put TELEGRAM_BOT_TOKEN + TELEGRAM_ALLOWED_USERS in"
    log "  $CONFIG"
    log "then re-run:  sudo bash $SCRIPT_DIR/$(basename "$0") $SVC"
  else
    if [ -n "$TOKEN_OWNER" ]; then
      OP_UID="$(id -u "$OPERATOR")"
      if runuser -u "$OPERATOR" -- env XDG_RUNTIME_DIR="/run/user/$OP_UID" \
           DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$OP_UID/bus" \
           systemctl --user is-enabled hermes-gateway >/dev/null 2>&1; then
        # Disable BEFORE starting: an enabled-but-stopped unit comes back at the
        # next boot and fights the new gateway for the same getUpdates offset.
        runuser -u "$OPERATOR" -- env XDG_RUNTIME_DIR="/run/user/$OP_UID" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$OP_UID/bus" \
          systemctl --user disable --now hermes-gateway || true
        log "stopped and disabled $OPERATOR's user gateway (shared bot token)"
      else
        log "$OPERATOR's user gateway is not enabled — nothing to stop"
      fi
    fi

    svc_systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || true
    svc_systemctl restart "$UNIT_NAME" || true

    if ! wait_active 30; then
      warn "gateway did not become active with the full sandbox"
      svc_systemctl status "$UNIT_NAME" || true
      journalctl _SYSTEMD_USER_UNIT="$UNIT_NAME.service" _UID="$SVC_UID" -n 40 --no-pager || true
      if [ "$ALLOW_DEGRADED" -eq 1 ]; then
        warn "--allow-degraded: retrying without ProtectHome"
        sed -i '/^ProtectHome=/d' "$DROPIN"
        svc_systemctl daemon-reload
        svc_systemctl restart "$UNIT_NAME" || true
        wait_active 30 || die "gateway still not active — inspect the journal above"
        warn "running DEGRADED: /home is readable (0700 still blocks other accounts)"
      else
        die "gateway is not active. Fix the journal error above, or re-run with
       --allow-degraded to drop ProtectHome (weaker). No state was rolled back."
      fi
    fi
    log "state: $(svc_systemctl is-active "$UNIT_NAME")"
  fi  # end DEFER_TELEGRAM guard
  chown -R "$SVC:$SVC" "$SVC_HERMES" "$SVC_HOME/.config"

fi  # end VERIFY_ONLY guard

# ------------------------------------------------------------- acceptance
SVC_UID="${SVC_UID:-$(id -u "$SVC" 2>/dev/null || true)}"
SVC_GID="${SVC_GID:-$(id -g "$SVC" 2>/dev/null || true)}"
[ -n "$SVC_UID" ] || die "$SVC does not exist — provision it first (drop --verify)"

say "9/9 acceptance tests"

check "no privileged groups on $SVC" bash -c \
  "! id -nG $SVC | tr ' ' '\n' | grep -Eqx 'sudo|wheel|docker|adm|lpadmin|ollama|systemd-journal'"

# sudo -l -U is authoritative and never prompts when run as root; the text is
# the only reliable signal (its exit status is 0 either way).
SUDO_OUT="$(sudo -l -U "$SVC" 2>&1 || true)"
case "$SUDO_OUT" in
  *"not allowed to run sudo"*|*"not in the sudoers"*)
    printf '   PASS  not a sudoer\n'; PASS=$((PASS+1)) ;;
  *"may run"*|*NOPASSWD*)
    printf '   FAIL  not a sudoer — sudo -l -U reports a grant\n'; FAIL=$((FAIL+1)) ;;
  *)
    if grep -rqsE "(^|[[:space:],])$SVC([[:space:],]|$)" \
         /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
      printf '   FAIL  not a sudoer — %s appears in a sudoers file\n' "$SVC"; FAIL=$((FAIL+1))
    else
      printf '   PASS  not a sudoer (static check; sudo -l -U gave no verdict)\n'; PASS=$((PASS+1))
    fi ;;
esac

check_neg "cannot read operator ssh keys"  runuser -u "$SVC" -- cat "$OPERATOR_HOME/.ssh/id_ed25519"
check_neg "cannot read operator .env"      runuser -u "$SVC" -- cat "$OP_ENV"
check_neg "cannot list operator home"      runuser -u "$SVC" -- ls "$OPERATOR_HOME"
check_neg "cannot write operator home"     runuser -u "$SVC" -- touch "$OPERATOR_HOME/pwn_test"
check_neg "cannot use the docker socket"   runuser -u "$SVC" -- docker ps

for d in /home/*; do
  b="$(basename "$d")"
  if [ "$b" = "$SVC" ]; then continue; fi
  case "$b" in
    hermes-*) check_neg "cannot read sibling account $b" runuser -u "$SVC" -- ls "$d" ;;
  esac
done

check "home is 0700"        bash -c "[ \"\$(stat -c %a $SVC_HOME)\" = 700 ]"
check "HERMES_HOME is 0700" bash -c "[ \"\$(stat -c %a $SVC_HERMES)\" = 700 ]"
check ".env is 0600"        bash -c "[ \"\$(stat -c %a $SVC_HERMES/.env)\" = 600 ]"
check "drop-in is 0600"     bash -c "[ \"\$(stat -c %a $DROPIN)\" = 600 ]"
check "linger enabled"      bash -c "[ \"\$(loginctl show-user $SVC -p Linger --value)\" = yes ]"
check "unit file installed" bash -c "[ -f \"$UNIT_FILE\" ]"
if [ "$DEFER_TELEGRAM" -eq 1 ]; then
  check_neg "user unit installed and left disabled (telegram pending)" \
    svc_systemctl is-enabled "$UNIT_NAME"
else
  check "user unit enabled"   unit_enabled
fi
check "no system unit claims this HERMES_HOME" bash -c \
  "! grep -qF 'HERMES_HOME=$SVC_HERMES' /etc/systemd/system/hermes-gateway*.service 2>/dev/null"

NNP="$(unit_prop NoNewPrivileges)"
if [ "$NNP" = yes ]; then
  printf '   PASS  NoNewPrivileges=yes\n'; PASS=$((PASS+1))
else
  printf '   FAIL  NoNewPrivileges=%s (want yes)\n' "${NNP:-<unset>}"; FAIL=$((FAIL+1))
fi

PROTECT_SYSTEM="$(unit_prop ProtectSystem)"
PROTECT_HOME="$(unit_prop ProtectHome)"
if [ "$PROTECT_SYSTEM" = strict ]; then
  printf '   PASS  ProtectSystem=strict\n'; PASS=$((PASS+1))
else
  printf '   FAIL  ProtectSystem=%s (want strict)\n' "${PROTECT_SYSTEM:-<unset>}"; FAIL=$((FAIL+1))
fi
case "$PROTECT_HOME" in
  read-only|yes) printf '   PASS  ProtectHome=%s\n' "$PROTECT_HOME"; PASS=$((PASS+1)) ;;
  *) printf '   FAIL  ProtectHome=%s (want read-only)\n' "${PROTECT_HOME:-<unset>}"; FAIL=$((FAIL+1)) ;;
esac

PID="$(main_pid)"
if [ "$DEFER_TELEGRAM" -eq 1 ] && { [ -z "$PID" ] || [ "$PID" = 0 ]; }; then
  warn "telegram deferred — no live process, so the namespace probes were not run"
  warn "  they run on the first provisioning pass that has a bot token"
elif [ -n "$PID" ] && [ "$PID" != 0 ] && [ -r "/proc/$PID/status" ]; then
  check "CapEff is empty"                  bash -c "grep -q '^CapEff:\s*0000000000000000' /proc/$PID/status"
  check "NoNewPrivs=1 on the live process" bash -c "grep -q '^NoNewPrivs:\s*1' /proc/$PID/status"
  check "runs as $SVC"                     bash -c "[ \"\$(stat -c %U /proc/$PID)\" = $SVC ]"

  # Root bypasses mode-0000 masks, so an ls-as-root check proves nothing. These
  # run inside the live mount namespace AND drop to the service uid.
  INNER="$(nsenter -t "$PID" -m -- stat -c '%d:%i' "$OPERATOR_HOME" 2>/dev/null || true)"
  OUTER="$(stat -c '%d:%i' "$OPERATOR_HOME" 2>/dev/null || true)"
  if [ -n "$INNER" ] && [ "$INNER" != "$OUTER" ]; then
    printf '   PASS  operator home is masked inside the service namespace\n'; PASS=$((PASS+1))
  else
    printf '   FAIL  operator home is NOT masked in the service namespace (inode %s vs %s)\n' \
      "${INNER:-none}" "${OUTER:-none}"; FAIL=$((FAIL+1))
  fi
  check_neg "live process (as $SVC) cannot list operator home" \
    nsenter -t "$PID" -m -- setpriv --reuid="$SVC_UID" --regid="$SVC_GID" --clear-groups ls "$OPERATOR_HOME"
  check "live process can read its own .env" \
    nsenter -t "$PID" -m -- setpriv --reuid="$SVC_UID" --regid="$SVC_GID" --clear-groups test -r "$SVC_HERMES/.env"
  check_neg "live process cannot write outside its home" \
    nsenter -t "$PID" -m -- setpriv --reuid="$SVC_UID" --regid="$SVC_GID" --clear-groups touch /etc/hermes_pwn_test
else
  warn "MainPID unavailable — skipping /proc and namespace checks"
fi

if [ "$DEFER_TELEGRAM" -eq 0 ]; then
  say "journal tail"
  journalctl _SYSTEMD_USER_UNIT="$UNIT_NAME.service" _UID="$SVC_UID" -n 20 --no-pager 2>/dev/null \
    || warn "journal unavailable for _UID=$SVC_UID"

  say "gateway self-report"
  if ! svc_hermes gateway status 2>&1; then warn "gateway status returned non-zero"; fi
else
  say "journal tail / gateway self-report"
  log "skipped — telegram is deferred, so the gateway has never run"
fi

# ------------------------------------------------------------ rollback doc
cat > "$ROLLBACK" <<EOF
# Rollback — $SVC gateway ($(date -Is))

## Stop it (keeps the account and its data)

    sudo -u $SVC env XDG_RUNTIME_DIR=/run/user/$SVC_UID \\
      systemctl --user disable --now $UNIT_NAME
    sudo loginctl disable-linger $SVC

## Hand the bot token back to $OPERATOR (only if this account reused it)

    systemctl --user enable --now hermes-gateway
    hermes gateway status

## Re-running this script (idempotent)

    sudo bash $SCRIPT_DIR/$(basename "$0") $SVC

## Full teardown

    sudo -u $SVC env XDG_RUNTIME_DIR=/run/user/$SVC_UID \\
      systemctl --user disable --now $UNIT_NAME
    sudo loginctl disable-linger $SVC
    sudo rm -rf $DROPIN_DIR $UNIT_FILE
    sudo userdel -r $SVC

Nothing was granted to $SVC outside $SVC_HOME, so there are no ACLs to revoke.
If grants are ever added, remove them BEFORE userdel — UIDs get reused:

    sudo setfacl -R -x u:$SVC <DIR>
    sudo find <DIR> -type d -exec setfacl -x d:u:$SVC {} +

## Residual exposure

Prompt injection inside the sandbox can still exfiltrate what the account can
read — its own .env (bot token + model key) — over its network egress. Use a
capped, rotatable model key.
EOF
if id "$OPERATOR" >/dev/null 2>&1; then chown "$OPERATOR:" "$ROLLBACK" 2>/dev/null || true; fi

printf '\n================ %d passed, %d failed, %d warnings ================\n' "$PASS" "$FAIL" "$WARN"
if [ "$DEFER_TELEGRAM" -eq 1 ]; then
  printf 'INCOMPLETE: sandbox installed, gateway not started (telegram deferred).\n'
  printf '  add TELEGRAM_BOT_TOKEN + TELEGRAM_ALLOWED_USERS to %s\n' "$CONFIG"
  printf '  then: sudo bash %s %s\n' "$SCRIPT_DIR/$(basename "$0")" "$SVC"
fi
printf 'log:      %s\nrollback: %s\n' "$LOG" "$ROLLBACK"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
