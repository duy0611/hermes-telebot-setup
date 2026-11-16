# Isolated Hermes Telegram gateway accounts

One script provisions one isolated gateway account. Run it again with a
different name to get a second, fully independent instance.

```
hermes-gateway-provision.sh     the only script you need
README.md                       this file
accounts/<account>.env          per-account Telegram + model config (0600)
legacy/                         the two superseded scripts, kept for reference
hermes-gateway-isolation-spec.md  the original design doc (system-unit era, superseded)
```

## Provision a second account

```
# 1. create a NEW bot with @BotFather (/newbot) and copy its token
#    (see "Getting the bot token and the allowed IDs" below)
#    --init-config needs no root: it only writes accounts/<account>.env
bash hermes-gateway-provision.sh hermes-telebot-wife --init-config

# 2. fill in TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USERS in
#    accounts/hermes-telebot-wife.env, then:

sudo bash hermes-gateway-provision.sh hermes-telebot-wife

# 3. check on it later, or after a host change
sudo bash hermes-gateway-provision.sh hermes-telebot-wife --verify
```

`--dry-run` resolves every input and prints the plan without touching the
system. Run it as root for a truthful plan (the account's `.env` is 0600).

## Getting the bot token and the allowed IDs

Two different numbers, and neither is a `@username`.

**Bot token** — create the bot with @BotFather (t.me/BotFather):

```
/newbot
  → display name   (anything, e.g. "Wife's Hermes")
  → username       (must be unique and end in "bot", e.g. wife_hermes_bot)
  → token          123456789:AAH...
```

The leading `123456789` is the *bot's* ID, not a person's. The Telegram account
that runs `/newbot` owns the bot and is the only one who can rename or revoke it,
so decide up front whose account creates it. Revoking a leaked token: @BotFather
`/revoke`.

**Allowed user IDs** — the numeric IDs of the humans allowed to talk to the bot:

- Message @userinfobot (or @get_id_bot) from that person's account; it replies
  with their ID, e.g. `1590306400`.
- Or, once that person has messaged the bot and nothing is polling the token:

```
TOKEN='123456789:AAH...'
curl -s "https://api.telegram.org/bot$TOKEN/getUpdates" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(sorted({u["message"]["from"]["id"] for u in d.get("result",[]) if "message" in u}))'
```

That fallback is why `--defer-telegram` pairs well with the manual route: no
gateway is polling, so `getUpdates` answers. Two consumers on one token get 409
and drop updates, so never run it while the account's gateway is up.

`TELEGRAM_HOME_CHANNEL` is the DM chat ID — for a DM that is the same number as
the person's user ID, so leave it blank and the script uses the first allowed ID.
Comma-separate multiple IDs; non-numeric entries are stripped with a warning.

**Do not run `hermes gateway setup`, or the dashboard's Messaging → Telegram →
"Create with QR", for these accounts** — unless you answer **no** to both
"Start the gateway now?" and "Start automatically on login/boot as a service?".
The QR flow genuinely creates the bot and auto-detects the owner's user ID, but a
"yes" there installs and starts a gateway outside the unit and drop-in this script
manages. If you use it: decline both, then run the provisioning script — it picks
up the token the wizard already wrote into the account's `.env`.

## Provision now, Telegram later

Yes — pass `--defer-telegram`. It creates the account, installs Hermes,
configures the model, writes the `.env` (without Telegram credentials), installs
the unit and the sandbox drop-in, then leaves the gateway **disabled and
stopped** so it cannot crash-loop waiting for a token.

```
sudo bash hermes-gateway-provision.sh hermes-telebot-wife --defer-telegram

# ... later, after @BotFather:
$EDITOR accounts/hermes-telebot-wife.env      # token + allowed user IDs
sudo bash hermes-gateway-provision.sh hermes-telebot-wife
```

The second run is the normal path: same script, same account, no flag. It adds
the `TELEGRAM_*` lines, enables the unit, starts it, and runs the full suite —
including the namespace probes, which are skipped in deferred mode because there
is no live process to inspect. Deferred runs end with an `INCOMPLETE:` line and
exit 0; only real failures exit non-zero.

## What it does

1. `useradd` an unprivileged account (no sudo/docker/adm/ollama groups), 0700 home.
2. Installs Hermes into `/home/<account>/.hermes` as that account (skipped if present).
3. Writes a minimal `.env` (bot token, allowed users, home channel, model key)
   and keeps any extra keys already there.
4. Points the model at the LiteLLM endpoint — inherited from
   `/home/hermes-telebot/.hermes/.env` by default (`--model-from`), so a new
   account is not left without a provider.
5. `loginctl enable-linger` + a **user-scope** `hermes-gateway.service` in that
   account's own manager, so it starts at boot with nobody logged in.
6. Adds a hardening drop-in (`NoNewPrivileges`, `ProtectSystem=strict`,
   `ProtectHome=read-only`, `InaccessiblePaths` for the operator and every
   sibling gateway account, `UMask=0077`, `MemoryMax=8G`, …).
7. Starts it and runs ~25 acceptance tests, including probes executed *inside*
   the live mount namespace as the service uid.
8. Writes `provision-<account>.log` and `rollback-<account>.md`.

## Invariants the script enforces

- **Never a system unit.** `hermes-gateway.service` in the system scope is a
  host-wide singleton: Hermes' runtime discovery matches the bare unit name for
  every account and fails closed with `service_account_mismatch` when `User=`
  is not the caller. That is what broke `dnguyen`'s own `hermes`. Per-account
  user units have no such collision.
- **Hardening in a drop-in, not the unit**, because `hermes gateway install`
  regenerates the unit on version changes and would erase inline directives.
- **One token, one poller.** If the token matches the operator's, the script
  refuses unless you pass `--reuse-operator-token`, in which case it disables
  the operator's gateway first. If it matches another gateway account's, it
  refuses outright.
- **No fallback that silently weakens the sandbox.** A failed start dies with
  the journal; dropping `ProtectHome` requires `--allow-degraded` and is logged
  as DEGRADED.

## Account config

`--init-config` writes this file for any account; a commented example lives at
`accounts/hermes-telebot-wife.env.example`.

```
TELEGRAM_BOT_TOKEN=          # required, from @BotFather
TELEGRAM_ALLOWED_USERS=      # required, numeric IDs, comma separated
TELEGRAM_HOME_CHANNEL=       # defaults to the first allowed ID
LITELLM_BASE_URL=            # optional; inherited from hermes-telebot if blank
LITELLM_API_KEY=
LITELLM_MODEL=
MODEL_PROVIDER=              # optional overrides
MODEL_DEFAULT=
APPROVALS_MODE=smart
```

Anything omitted falls back in this order: `--config FILE` →
`accounts/<account>.env` → `<account>.secrets` (legacy) → the account's live
`.env` → (token only, with `--reuse-operator-token`) the operator's `.env`.

## Rollback

`rollback-<account>.md` is generated per account and contains the exact
commands. The short version:

```
sudo -u hermes-telebot-wife env XDG_RUNTIME_DIR=/run/user/<uid> \
  systemctl --user disable --now hermes-gateway
sudo loginctl disable-linger hermes-telebot-wife
sudo userdel -r hermes-telebot-wife
```

## Known limits

- Each account needs its **own bot token**; sharing one token between pollers
  corrupts the `getUpdates` offset.
- The sandbox limits blast radius, not the likelihood of a bad action: prompt
  injection can still exfiltrate what the account can read (its own `.env`)
  over its network egress. Use a capped, rotatable model key per account.
- No GUI for these accounts (`computer_use`, clipboard, X/Wayland).
- `ProtectHome` and the sibling masks rely on the `--user` manager being able
  to build mount namespaces on this host; the script fails loudly if a future
  systemd build refuses.
