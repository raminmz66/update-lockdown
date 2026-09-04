# update-lockdown — Design

**Date:** 2026-09-04
**Status:** Approved
**Target system:** Ubuntu 22.04.5 LTS (jammy), snapd 2.76.2, bash 5.1

## Problem

Ubuntu applies updates from several independent background mechanisms — apt
timers, unattended-upgrades, snapd auto-refresh, firmware refresh, and
notifier timers. Turning them off means touching each one, and turning them
back on means remembering exactly what each was set to. Doing that by hand is
error-prone and, in practice, irreversible.

`update-lockdown` freezes all of them with one command and restores the exact
prior state with another.

## Requirements

1. **Background only.** When locked, nothing installs on its own. Manual
   `sudo apt upgrade` and `sudo snap refresh` continue to work normally.
2. **Exactly reversible.** `unlock` restores the precise state captured at
   `lock` time — not Ubuntu's stock defaults.
3. **Survives reboots and package reinstalls.**
4. **Re-asserted at boot** by a systemd unit, so drift cannot silently
   reopen a channel.
5. **No runtime dependencies** beyond coreutils, systemd and snapd. `jq` is
   not installed on the target and must not become a requirement.

### Out of scope

Applications carrying their own updater outside apt and snap (VS Code's
built-in updater, JetBrains Toolbox, Claude Code). PhpStorm and Slack on this
machine are snaps and therefore covered. `snapd.snap-repair.timer` is left
enabled deliberately — it is Canonical's out-of-band channel for repairing a
broken snapd, and disabling it risks an unrecoverable snapd.

## Interface

```
sudo update-lockdown lock      # snapshot current state, then freeze
sudo update-lockdown unlock    # restore the snapshot, then forget it
     update-lockdown status    # report every managed item
sudo update-lockdown enforce   # re-apply the frozen state; used at boot
```

Global flags: `--dry-run` (print every action, change nothing),
`--quiet`, `--help`, `--version`.

`lock`, `unlock` and `enforce` require root and exit 3 without it. `status`
runs as any user; snapd fields it cannot read as non-root are reported as
`unknown` rather than treated as drift.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. For `status`: locked and fully consistent. |
| 1 | For `status`: not locked (no state file). Not an error. |
| 2 | For `status`: locked but drifted — at least one item is not in its frozen state. |
| 3 | Usage error, missing privileges, or a failed operation. |

## State model

State file: `/var/lib/update-lockdown/state.tsv`, mode `0600`, owned by root.
**Its presence is the single source of truth for "locked".**

Tab-separated, one record per line, `#`-prefixed comments ignored:

```
#update-lockdown state
schema	1
locked_at	2026-09-04T21:12:03+03:30
unit	apt-daily.timer	enabled	active
unit	apt-daily.service	static	inactive
unit	unattended-upgrades.service	enabled	active
aptconf	99-update-lockdown	absent
snap	refresh.hold	__unset__
```

Field 1 is the record kind (`unit`, `aptconf`, `snap`, or a bare metadata
key). Parsing uses `IFS=$'\t' read -r`, so no JSON parser is needed.

### Ordering rule

**The snapshot is written to disk before any change is applied.** If the
process dies mid-apply, `unlock` still has everything it needs to restore.

### The overwrite guard

`lock` refuses to run when a state file already exists, and exits 3 with a
message pointing at `unlock`. Without this guard a second `lock` would
snapshot the already-frozen values as though they were the originals,
destroying the real snapshot irrecoverably. This is the single most important
invariant in the design.

`unlock` restores item by item and deletes the state file only after every
item succeeds. A partial failure leaves the file in place so `unlock` can
simply be run again; it is idempotent.

## Managed items

### 1. systemd units

Snapshot records `systemctl is-enabled` and `systemctl is-active` per unit.

**Lock:** stop the unit; `disable` it only when its recorded enabled-state was
literally `enabled` (calling `disable` on a static unit is an error on
systemd 249); then `mask` it. Masking rather than merely disabling is
deliberate — `apt install --reinstall unattended-upgrades` re-enables its own
timer, and a mask survives that.

**Restore,** driven by the recorded enabled-state:

| Recorded | Action |
|---|---|
| `not-found` | Skip entirely; the unit does not exist here. |
| `enabled` | `unmask`, `enable`, and `start` if it was active. |
| `disabled` | `unmask`, `disable`. Never start. |
| `static`, `indirect`, `enabled-runtime` | `unmask` only; `start` if it was active. |
| `masked` | Leave masked — that is how it was found. |

Managed units:

| Unit | State when surveyed |
|---|---|
| `apt-daily.timer` | enabled / active |
| `apt-daily-upgrade.timer` | enabled / active |
| `apt-daily.service` | static |
| `apt-daily-upgrade.service` | static |
| `unattended-upgrades.service` | enabled / active |
| `fwupd-refresh.timer` | enabled / active |
| `packagekit-offline-update.service` | static |
| `update-notifier-download.timer` | enabled / active |
| `update-notifier-motd.timer` | enabled / active |
| `motd-news.timer` | enabled / active |
| `apt-news.service` | static |

A unit absent from the system is recorded `not-found` and skipped in both
directions, so the same script runs on a machine without, say, `fwupd`.

`update-lockdown.service` itself is never a managed unit.

### 2. apt configuration

**Lock** writes `/etc/apt/apt.conf.d/99-update-lockdown`:

```
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::AutocleanInterval "0";
```

It sorts last in `apt.conf.d`, so it wins over `10periodic`. **`10periodic` is
never modified**, which is what makes the exact-restore promise cheap to keep
for apt. Unlock deletes the drop-in.

If a file of that name already exists at lock time it is moved to
`/var/lib/update-lockdown/backup/` and restored on unlock; the snapshot
records `present` rather than `absent`.

### 3. snapd auto-refresh

**Lock:** `snap set system refresh.hold=forever`, supported since snapd 2.58.
This holds *automatic* refreshes while leaving manual `snap refresh` working —
precisely the background-only behaviour required. `snap refresh --hold` was
rejected because it also blocks manual refreshes.

**Snapshot:** `snap get system refresh.hold`, recorded as `__unset__` when
unset or unreadable.

**Restore:** `snap unset system refresh.hold` when the record is `__unset__`,
otherwise `snap set system refresh.hold=<recorded value>`.

## Boot-time enforcement

`/etc/systemd/system/update-lockdown.service`:

```ini
[Unit]
Description=Re-apply update lockdown
After=snapd.service
Wants=snapd.service
ConditionPathExists=/var/lib/update-lockdown/state.tsv

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/update-lockdown enforce --quiet

[Install]
WantedBy=multi-user.target
```

`enforce` re-applies the frozen target for every item named in the state file
**without ever writing to the state file**. With no state file it exits 0
silently — the `ConditionPathExists` makes that the normal no-op path.

Masks already survive reboots on their own; `enforce` exists to close the gap
where a package upgrade or a manual `systemctl unmask` reopens a channel
between boots.

## Error handling

- `set -euo pipefail`; every external call is wrapped so a single item's
  failure is reported and recorded but does not abort the remaining items.
- The script reports a per-item summary and exits 3 if any item failed.
- Re-running `unlock` when not locked prints a message and exits 0.
- Re-running `lock` when locked exits 3 (see the overwrite guard).

## Testability

The script reads three path overrides from the environment, defaulting to the
real system locations, so tests never touch the host:

| Variable | Default |
|---|---|
| `UL_STATE_DIR` | `/var/lib/update-lockdown` |
| `UL_APT_CONF_DIR` | `/etc/apt/apt.conf.d` |
| `UL_ALLOW_NONROOT` | unset (set to `1` in tests) |

`tests/fake-bin/` provides stub `systemctl` and `snap` executables prepended
to `PATH`. They answer queries from a scripted fixture and append every
invocation to `$UL_FAKE_LOG`, letting tests assert the exact command sequence.

`tests/run-tests.sh` is plain bash with no external dependencies. Coverage:

1. `lock` writes a snapshot matching the fixture before issuing any change.
2. `lock` masks each unit and skips `disable` for static units.
3. `lock` refuses to run twice and leaves the first snapshot byte-identical.
4. `unlock` restores enabled/disabled/static/masked/not-found correctly.
5. `unlock` removes the apt drop-in and restores a pre-existing one.
6. `snap refresh.hold` round-trips through both `__unset__` and a real value.
7. `enforce` re-applies without modifying the state file.
8. `status` exit codes: 1 unlocked, 0 locked-clean, 2 locked-drifted.
9. `--dry-run` mutates nothing — no state file, no fake-bin write calls.

## Repository layout

```
update-lockdown/
  update-lockdown            # the script
  install.sh                 # install to /usr/local/bin + enable boot unit
  uninstall.sh               # unlock if locked, then remove
  systemd/update-lockdown.service
  tests/
    run-tests.sh
    fake-bin/{systemctl,snap}
  docs/superpowers/specs/2026-09-04-update-lockdown-design.md
  README.md
```
