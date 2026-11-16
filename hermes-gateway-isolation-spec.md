# Spec: Isolate the Hermes Telegram Gateway in a Dedicated Unix User

**Status:** proposed — not implemented
**Author:** Hermes (default profile, running as `dnguyen`)
**Audience:** a human operator with `sudo`, plus the Hermes agent executing the migration

---

## 1. Objective

Move the always-on messaging gateway (Telegram) off the interactive user
`dnguyen` and onto a dedicated, unprivileged Unix user `hermes`, so that the
untrusted-input path (a Telegram message, a prompt injection in a fetched page,
a malicious file) can no longer reach root-equivalent capability or the
operator's personal data.

**In scope**

- New Unix user with no `sudo`, no `docker`, no `ollama` membership.
- Fresh `HERMES_HOME` for that user, minimal secret set.
- Hardened **system-level** systemd unit (not a user unit) with sandboxing.
- Second Telegram bot so the new instance does not contend for the old
  bot's `getUpdates` long-poll.
- Selective, explicit file access via POSIX ACLs to named project directories.
- Acceptance tests that prove the containment actually holds.

**Out of scope**

- Migrating chat history / skills / memory (optional, see §11; default is a
  clean instance).
- The interactive Hermes instance on `dnguyen` — it stays as-is.
- Network egress filtering (see §10).

---

## 2. Current state (verified, 2026-11-05)

Re-verify these before starting; do not trust this section blind.

| Fact | Value | Verified with |
|---|---|---|
| OS | Ubuntu 24.04.3 LTS, systemd 255 | `. /etc/os-release`; `systemctl --version` |
| Hermes version | v0.22.7 (2026.9.24), stable | `hermes --version` |
| Install dir | `/home/dnguyen/.hermes/hermes-agent` | `hermes --version` |
| CLI | `/home/dnguyen/.local/bin/hermes` | `command -v hermes` |
| `HERMES_HOME` | `/home/dnguyen/.hermes` | unit file |
| Gateway service | **user** unit `hermes-gateway.service`, `Linger=yes` | `systemctl --user list-units` |
| `dnguyen` groups | `sudo adm cdrom dip plugdev lpadmin docker ollama` | `id` |
| `dnguyen` sudo | password-gated, in `%sudo` (only member) | `sudo -n -l` → "a password is required" |
| Docker socket | `/var/run/docker.sock`, group `docker`, `rw` to `dnguyen` | `ls -l` |
| Ollama | active, `http://127.0.0.1:11434` → 200 | `curl` |
| Secrets at risk | `~/.ssh/id_ed25519`, `~/.hermes/.env` (27 KB), `~/.hermes/config.yaml` | `ls -l` |
| Telegram config lives in | `~/.hermes/.env` (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`, `TELEGRAM_HOME_CHANNEL`) | `grep -oE '^[A-Z0-9_]+'` |
| ACL tooling | `setfacl`/`getfacl` present | `command -v` |
| Free space on `/home` | 336 G | `df -h /home` |

**Blast radius today:** the gateway process runs as `dnguyen`, therefore it can
read the operator's SSH key, all `.env` provider keys, and every project
directory — and can escalate to root without a password via the `docker` group
(`docker run -v /:/host --privileged`). The `0700` mode on `~/.hermes` gives no
protection because the agent *is* the owning user.

Existing unit, for reference (read it fresh before copying anything):

```
~/.config/systemd/user/hermes-gateway.service
ExecStart="/home/dnguyen/.hermes/hermes-agent/.hermes/bin/hermes" "gateway" "run"
Environment="HERMES_HOME=/home/dnguyen/.hermes"
Environment="HERMES_SUPERVISED_CHILD=1"
Restart=always  RestartSec=5  KillMode=mixed  TimeoutStopSec=210
ExecReload=/bin/kill -USR1 $MAINPID
ExecStop=-".../hermes" "--run-module" "gateway.systemd_stop_mark"
ExecStopPost=-".../hermes" "--run-module" "gateway.cgroup_cleanup"
```

---

## 3. Target architecture

```
Telegram (bot #2)  ──►  systemd system unit: hermes-gateway.service
                          User=hermes  Group=hermes
                          NoNewPrivileges, ProtectSystem=strict,
                          ProtectHome=read-only + ReadOnlyPaths=/home/dnguyen
                          ReadWritePaths=/home/hermes, granted project dirs
                              │
                              └─► /home/hermes/.hermes        (private, 0700)
                                  /home/hermes/projects/*     (ACL-granted)

Telegram (bot #1)  ──►  systemd user unit under dnguyen   (unchanged, interactive)
```

Two bots, two tokens, two OS users. They never share a process, a home
directory, or a Telegram long-poll.

---

## 4. Decisions the operator must make first

Fill these in before writing any command. The executing agent must stop and
ask if any are blank.

1. **Username** — default `hermes`. Must not already exist (`id hermes`).
2. **Shell / home** — default `/bin/bash`, `/home/hermes`.
3. **Telegram bot** — create a *second* bot via @BotFather (`/newbot`), record
   the token. Do **not** reuse the existing token (see §7.4).
4. **Allowed user IDs** — numeric Telegram IDs permitted to talk to it.
   Current DM chat ID for David is in `TELEGRAM_HOME_CHANNEL` (`.env`), and
   `TELEGRAM_ALLOWED_USERS` in the current `.env` is the authoritative list —
   reuse those values, re-read the file rather than trusting this doc.
5. **Project directories to grant** — explicit absolute paths, e.g.
   `~/projects/foo`, `~/work/bar`. Everything else stays unreadable.
6. **Model provider strategy** — pick one:
   - (a) dedicated API key with a spend cap (**recommended**), or
   - (b) `hermes portal` login as `hermes`, or
   - (c) copy the existing `OPENROUTER_API_KEY` (weakest — same key, same
     blast radius if leaked).
7. **History/skills migration** — yes/no (§11).
8. **Cron jobs** — migrate, or leave on `dnguyen` (§11).

---

## 5. Phase 0 — Pre-flight

Run as `dnguyen`, no privileges needed.

```bash
id hermes 2>&1                      # expect: no such user
df -h /home                        # need > 3 GB
hermes gateway status              # record current state for rollback
systemctl is-enabled hermes-gateway --user   # user unit state
```

Record the old bot token, allowed users, and current unit file to a rollback
note (§13) before touching anything.

---

## 6. Phase 1 — Create the isolated user

Requires `sudo`. The executing agent cannot type a sudo password; either the
operator runs these, or the operator adds a **temporary, narrow** NOPASSWD
rule and removes it in Phase 9:

```
# /etc/sudoers.d/90-hermes-provision   (temporary, delete afterwards)
dnguyen ALL=(root) NOPASSWD: /usr/sbin/useradd, /usr/sbin/usermod, \
                              /usr/bin/setfacl, /usr/bin/getfacl, \
                              /bin/systemctl, /usr/bin/install, /bin/chown
```

Commands:

```bash
sudo useradd --create-home --shell /bin/bash --comment "Hermes gateway" hermes
sudo passwd --lock hermes                  # no login password; use runuser -u
sudo chmod 0700 /home/hermes
sudo install -d -o hermes -g hermes -m 0700 /home/hermes/.hermes /home/hermes/projects
```

**Hard requirement — verify, do not assume:**

```bash
id hermes
# MUST print exactly: uid=...(hermes) gid=...(hermes) groups=...(hermes)
# MUST NOT contain: sudo, wheel, docker, adm, lpadmin, ollama

sudo -u hermes sudo -n -l 2>&1 | head -1
# MUST contain "not in the sudoers file" — a password prompt means it IS a sudoer
```

If `hermes` shows up in `docker` or `sudo`, stop; the whole exercise is void.

---

## 7. Phase 2 — Install Hermes for `hermes`

```bash
# install.sh URL verified against ~/.hermes/hermes-agent/README.md ("Quick Install")
sudo -u hermes -H bash -lc 'export HERMES_HOME=/home/hermes/.hermes; \
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
```

If an offline/vendored installer is preferred, copy the existing install and
`chown -R hermes:hermes` it — but a clean install avoids inheriting
`~/.hermes` secrets, sessions, and caches.

Verify:

```bash
sudo -u hermes -H bash -lc 'export HERMES_HOME=/home/hermes/.hermes; \
  hermes --version; hermes doctor'
```

### 7.1 Minimal environment

Create `/home/hermes/.hermes/.env`, mode `0600`, owner `hermes`, containing
**only** what this instance needs:

```
TELEGRAM_BOT_TOKEN=<new bot token>
TELEGRAM_ALLOWED_USERS=<numeric IDs, comma-separated>
TELEGRAM_HOME_CHANNEL=<default DM chat id>
OPENROUTER_API_KEY=<dedicated capped key>
```

Do **not** copy `dnguyen`'s `.env`. It holds unrelated tool credentials
(Browserbase, vision, web tools) that the gateway does not need, and every
copied key widens what a compromise yields.

### 7.2 Model + agent config

```bash
sudo -u hermes -H bash -lc 'export HERMES_HOME=/home/hermes/.hermes; \
  hermes model; hermes gateway setup'
```

Non-interactive alternative: `hermes model --provider <p> --model <m>` (check
`hermes model --help` — flag names drift between versions).

### 7.3 Generate the unit, then harvest it

```bash
sudo -u hermes -H bash -lc 'export HERMES_HOME=/home/hermes/.hermes; \
  hermes gateway install'
sudo -u hermes cat /home/hermes/.config/systemd/user/hermes-gateway.service
```

Copy the exact `ExecStart=` path, `PATH=`, and the
`ExecReload`/`ExecStop`/`ExecStopPost` lines into Phase 3. Those encode
version-specific behaviour (`--run-module gateway.systemd_stop_mark`, the
`.hermes/bin/hermes` wrapper path) that must not be guessed.

Then remove the generated user unit so only one supervisor exists:

```bash
sudo -u hermes systemctl --user disable --now hermes-gateway 2>/dev/null || true
sudo -u hermes rm -f /home/hermes/.config/systemd/user/hermes-gateway.service
```

`loginctl enable-linger` is **not** needed — the system unit runs outside a
user session.

### 7.4 Telegram token contention (read this)

Telegram delivers each update to exactly one `getUpdates` consumer. Two
processes polling **the same token** fight: dropped messages, `409 Conflict`,
corrupt offsets. Two options:

- **Recommended:** new bot from @BotFather → new token → no contention, old
  gateway keeps running untouched.
- Or reuse the token: then `systemctl --user disable --now hermes-gateway`
  **before** starting the new unit, and accept the downtime/flip.

---

## 8. Phase 3 — Hardened system unit

`/etc/systemd/system/hermes-gateway.service`:

```ini
[Unit]
Description=Hermes Agent Gateway (isolated user)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=hermes
Group=hermes
WorkingDirectory=/home/hermes/.hermes
Environment="HERMES_HOME=/home/hermes/.hermes"
Environment="HERMES_SUPERVISED_CHILD=1"
Environment="PATH=/home/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin"
# ^ replace with the PATH harvested from the generated unit in §7.3
ExecStart=<EXACT ExecStart from §7.3>
ExecReload=/bin/kill -USR1 $MAINPID
ExecStop=-<EXACT ExecStop from §7.3>
ExecStopPost=-<EXACT ExecStopPost from §7.3>
Restart=always
RestartSec=5
RestartForceExitStatus=75
SuccessExitStatus=75
RestartPreventExitStatus=78
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=210
StandardOutput=journal
StandardError=journal

# --- sandboxing ---
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/hermes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
CapabilityBoundingSet=
AmbientCapabilities=
LockPersonality=yes
SystemCallArchitectures=native
UMask=0077
MemoryMax=8G
TasksMax=512

[Install]
WantedBy=multi-user.target
```

Notes and gotchas:

- `ProtectSystem=strict` makes `/` read-only; `ReadWritePaths=/home/hermes`
  is what keeps the gateway able to write its own state, sessions, and logs.
  **Any** granted project dir that must be writable goes in `ReadWritePaths`
  too; read-only grants need `ReadOnlyPaths=` instead.
- `ProtectHome=read-only` leaves `/home/dnguyen` **readable**. Combine with
  `ReadOnlyPaths=/home/dnguyen/.ssh /home/dnguyen/.hermes` if those must be
  hidden, or `ProtectHome=yes` if the gateway needs no access to `/home/dnguyen`
  at all (then drop the ACL grants in Phase 4 — the two are complementary
  choices, pick one).
- `RestrictNamespaces=yes` blocks `unshare`/user namespaces. Verify the browser
  toolset still works if it is enabled — Chromium's sandbox may need
  `RestrictNamespaces=no` or `chrome-sandbox` SUID. Test before finalising;
  drop the line if it breaks browsing.
- Do **not** add `IPAddressDeny=any` here: it kills model-provider egress.
  Egress control is §10.
- `CapabilityBoundingSet=` empty is safe for a non-root user; it guarantees no
  capability is ever raised.

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now hermes-gateway
systemctl status hermes-gateway --no-pager
journalctl -u hermes-gateway -n 80 --no-pager
```

---

## 9. Phase 4 — Selective file access (ACLs)

Grant per-directory access, never a blanket `chmod`. ACLs are the only
mechanism that coexists with `0750`/`0700` homes.

For each directory `DIR` in the owner's list:

```bash
# traverse + read for existing content, recursively
sudo setfacl -R -m u:hermes:rX  "$DIR"
# default ACLs so files created LATER are also readable
sudo find "$DIR" -type d -exec setfacl -m d:u:hermes:rX {} +
```

For directories the agent must *write*:

```bash
sudo setfacl -R -m u:hermes:rwX "$DIR"
sudo find "$DIR" -type d -exec setfacl -m d:u:hermes:rwX {} +
```

Verify with `getfacl "$DIR"` — you want both an `user:hermes:...` entry and a
`default:user:hermes:...` entry.

Caveats to state plainly to the operator:

- ACLs are inherited only where default ACLs exist. A directory created later
  inside a tree that lacks default ACLs will not be accessible.
- `git` operations that rewrite permissions, `rsync --archive` to a non-ACL
  filesystem, and archives extracted with `tar --no-acl` can drop entries.
- `d:u:...` on a directory does not retroactively cover existing files; that's
  why both `-R` and the `find` pass are required.

---

## 10. Phase 5 — Verification / acceptance tests

All must pass. Run them as the operator, not trusting the agent's summary.

**Isolation**

```bash
id hermes | grep -Eq 'sudo|docker|adm|lpadmin|ollama' && echo FAIL || echo PASS
sudo -u hermes sudo -n -l 2>&1 | grep -q 'not in the sudoers' && echo PASS || echo FAIL
sudo -u hermes cat /home/dnguyen/.ssh/id_ed25519 >/dev/null 2>&1 && echo FAIL || echo PASS
sudo -u hermes cat /home/dnguyen/.hermes/.env    >/dev/null 2>&1 && echo FAIL || echo PASS
sudo -u hermes docker ps >/dev/null 2>&1          && echo FAIL || echo PASS
sudo -u hermes ls /home/dnguyen/Documents >/dev/null 2>&1 && echo FAIL || echo PASS
sudo -u hermes touch /home/dnguyen/pwn_test 2>&1 | grep -q 'Permission denied' && echo PASS || echo FAIL
```

**Sandbox actually applied**

```bash
systemctl show hermes-gateway -p NoNewPrivileges -p ProtectSystem -p ProtectHome -p ReadWritePaths
# expect NoNewPrivileges=yes, ProtectSystem=strict, ProtectHome=read-only
pid=$(systemctl show -p MainPID --value hermes-gateway)
grep -E 'CapEff|NoNewPrivs' /proc/$pid/status   # CapEff=0000000000000000, NoNewPrivs=1
```

**Functionality**

1. Message the new bot from an allowed account → reply arrives.
2. Message from a non-allowed account → ignored/refused.
3. In-chat, ask it to read a granted project file → works.
4. In-chat, ask it to read `/home/dnguyen/.hermes/.env` → denied.
5. In-chat, ask it to run `docker ps` → denied.
6. Restart the host (or `systemctl restart`) → gateway comes back with no
   login by anyone.
7. `hermes gateway status` as `hermes` reports healthy; `journalctl` shows no
   crash loop.
8. Browser toolset: open one page, confirm Chromium sandbox didn't break.
9. Cron jobs (if migrated): fire one manually, confirm delivery.
10. `/home/hermes` and `~/.hermes` both `0700`, `.env` `0600`:
    `ls -ld /home/hermes /home/hermes/.hermes; ls -l /home/hermes/.hermes/.env`

---

## 11. Phase 6 — Optional migration

**Skills** (safe, portable):

```bash
sudo rsync -a /home/dnguyen/.hermes/skills/ /home/hermes/.hermes/skills/
sudo chown -R hermes:hermes /home/hermes/.hermes/skills
```

**Memory**: `memory/user.md` and `memory/memory.md` — copy only if the new
instance should share identity/preferences. They often encode paths the
sandboxed instance cannot reach; review before copying.

**Cron jobs**: `~/.hermes/cron/` holds schedules *and* delivery targets. Jobs
that touch `~/` paths will fail under the new user. Default recommendation:
leave cron on `dnguyen`, migrate individual jobs later once their paths are
ACL-granted.

**Sessions/history**: do not migrate. They contain transcripts of everything
the unrestricted agent ever read.

---

## 12. Phase 7 — Cleanup

```bash
sudo rm -f /etc/sudoers.d/90-hermes-provision     # if it was created
sudo visudo -c                                     # syntax check
ls -l /etc/sudoers.d/
```

Confirm the old user unit is still enabled and healthy if you kept the
`dnguyen` gateway, or disable it if you consolidated onto one bot.

---

## 13. Rollback

Fast, no data loss, both directions:

```bash
# stop the isolated instance
sudo systemctl disable --now hermes-gateway

# restore the old one (if it was disabled for token reuse)
systemctl --user enable --now hermes-gateway
hermes gateway status

# full teardown, only after confirming nothing is needed
sudo userdel -r hermes
sudo rm -f /etc/systemd/system/hermes-gateway.service
sudo systemctl daemon-reload
```

ACL grants survive `userdel` — UIDs are reused, which is a real hazard. Remove
them explicitly:

```bash
for d in <GRANTED_DIRS>; do
  sudo setfacl -R -x u:hermes "$d"
  sudo find "$d" -type d -exec setfacl -x d:u:hermes {} +
done
```

---

## 14. Risks and residual exposure

State these to the operator; none are fixed by this migration.

1. **Exfiltration of granted data.** Anything ACL-granted is readable *and*
   the process has network egress. An injected instruction can POST a file to
   an attacker. Mitigation: grant the minimum, prefer read-only.
2. **Model provider key.** If the sandboxed instance holds a key, that key is
   now reachable by injected code. Use a capped, rotatable key.
3. **Telegram bot token** lives in the sandboxed `.env`. Leaking it lets
   someone impersonate the bot, not the operator.
4. **Prompt injection remains the primary threat model** — the sandbox limits
   consequences, not the likelihood of a bad action inside the sandbox.
5. **`dnguyen` still has `sudo` + `docker`.** Splitting the gateway helps only
   because the risky process no longer runs there. Independently consider
   removing `docker` group membership (`sudo docker` when needed) — that is
   the single cheapest risk reduction available and needs no new user.
6. **No GUI.** `computer_use`, clipboard, X/Wayland access are unavailable to
   the isolated user. If the gateway must drive a desktop, this design is
   wrong; use a separate desktop session user instead.
7. **Egress firewall** — `hermes egress` (iron-proxy credential injection) is
   available as a follow-up layer; out of scope here.

---

## 15. Appendix — command reference

```bash
# state
hermes gateway status
hermes gateway list              # all profiles + status
systemctl status hermes-gateway  # system unit
journalctl -u hermes-gateway -f

# as the isolated user
sudo -u hermes -H bash -lc 'export HERMES_HOME=/home/hermes/.hermes; hermes doctor'

# regenerate the unit from the installed version
sudo -u hermes -H bash -lc 'export HERMES_HOME=/home/hermes/.hermes; hermes gateway install'
```

Relevant CLI surface (v0.22.7): `hermes gateway {run,ensure,start,stop,restart,status,install,uninstall,list,setup,migrate,enroll}`,
`hermes setup`, `hermes model`, `hermes doctor`, `hermes egress`, `hermes cron`.

---

## 16. Definition of done

- [ ] `hermes` exists, sole member of its own group, absent from `sudo`/`docker`/`adm`/`lpadmin`/`ollama`.
- [ ] `sudo -u hermes sudo -n -l` → "not in the sudoers file".
- [ ] All eight §10 isolation tests PASS.
- [ ] `CapEff=0000000000000000`, `NoNewPrivs=1` on the live MainPID.
- [ ] New bot answers an allowed user; ignores a non-allowed one.
- [ ] In-chat read of `/home/dnguyen/.hermes/.env` and `docker ps` both denied.
- [ ] Survives reboot without any login.
- [ ] No crash loop; `Restart=always` proven by killing the PID once.
- [ ] Temporary sudoers rule removed, `visudo -c` clean.
- [ ] Rollback (§13) documented in the operator's notes, including the old unit's enabled state.
```
