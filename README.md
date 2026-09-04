# update-lockdown

Freeze every background update mechanism on Ubuntu with one command, and put
everything back **exactly** as it was with another.

Ubuntu updates itself from several independent places — apt timers,
unattended-upgrades, snapd auto-refresh, firmware refresh, notifier timers.
Turning them all off by hand means touching each one; turning them back on
means remembering what each was set to. `update-lockdown` snapshots that state
before it changes anything, so re-enabling is exact rather than approximate.

```console
$ sudo update-lockdown lock
snapshot written to /var/lib/update-lockdown/state.tsv
  freezing apt-daily.timer (was enabled/active)
  freezing unattended-upgrades.service (was enabled/active)
  ...
  writing /etc/apt/apt.conf.d/99-update-lockdown
  holding snap auto-refresh (manual 'snap refresh' still works)

Updates are locked down. Manual 'apt upgrade' and 'snap refresh' still work.
```

## Background only — by design

While locked, **nothing installs on its own**. Your own commands are
untouched:

```bash
sudo apt update && sudo apt upgrade   # works normally
sudo snap refresh                     # works normally
```

That is deliberate. The tool uses snapd's `refresh.hold` option, which holds
*automatic* refreshes, rather than `snap refresh --hold`, which would also
block the refreshes you ask for.

## Install

```bash
git clone git@github.com:raminmz66/update-lockdown.git
cd update-lockdown
sudo ./install.sh
```

That puts the script in `/usr/local/bin` and enables a systemd unit that
re-applies the lockdown at every boot. The unit stays inert until you run
`lock` at least once.

## Commands

| Command | What it does |
|---|---|
| `sudo update-lockdown lock` | Snapshot the current state, then freeze everything |
| `sudo update-lockdown unlock` | Restore that snapshot exactly, then forget it |
| `update-lockdown status` | Report every managed item; no root needed |
| `sudo update-lockdown enforce` | Re-apply the frozen state (what the boot unit runs) |

Flags: `--dry-run` (print every action, change nothing), `--quiet`,
`--help`, `--version`.

Run `update-lockdown lock --dry-run` first if you want to see the plan before
committing to it.

## What gets frozen

**systemd units** — stopped, disabled where applicable, then *masked*.
Masking rather than merely disabling matters: `apt install --reinstall
unattended-upgrades` re-enables its own timer, and a mask survives that.

| Unit | Why |
|---|---|
| `apt-daily.timer`, `apt-daily.service` | Background `apt update` |
| `apt-daily-upgrade.timer`, `apt-daily-upgrade.service` | Background `apt upgrade` |
| `unattended-upgrades.service` | Automatic security updates |
| `fwupd-refresh.timer` | Firmware metadata refresh |
| `packagekit-offline-update.service` | Applies downloaded updates at boot |
| `update-notifier-download.timer`, `update-notifier-motd.timer` | Update nag popups |
| `motd-news.timer`, `apt-news.service` | Ubuntu news/ads in the login banner |

**apt** — writes `/etc/apt/apt.conf.d/99-update-lockdown` setting every
`APT::Periodic::*` counter to `0`. It sorts last, so it wins, and your
existing `10periodic` is **never modified**. Unlock deletes the drop-in.

**snapd** — sets `refresh.hold=forever` (needs snapd ≥ 2.58). Your previous
value, if any, is recorded and restored on unlock.

## Automatic at boot

`install.sh` enables `update-lockdown.service`, a oneshot unit that runs
`update-lockdown enforce` after `snapd.service`. Masks already survive a
reboot on their own — `enforce` exists to close the gap where a package
upgrade or a stray `systemctl unmask` reopens a channel between boots. If
nothing has drifted it does nothing.

```bash
systemctl status update-lockdown.service   # see what it did at last boot
```

## How the state file works

`/var/lib/update-lockdown/state.tsv`, mode `0600`, tab-separated so no JSON
parser is needed. **Its presence is what "locked" means.**

```
schema	1
locked_at	2026-09-04T21:12:03+03:30
unit	apt-daily.timer	enabled	active
unit	apt-news.service	static	inactive
aptconf	99-update-lockdown	absent
snap	refresh.hold	__unset__
```

Two rules keep it trustworthy:

1. **The snapshot is written before anything is changed.** If the process dies
   halfway through a lock, `unlock` still has everything it needs.
2. **`lock` refuses to run when a snapshot already exists.** Without that
   guard, a second `lock` would record the already-frozen values as if they
   were your originals and destroy the real ones irrecoverably. Run `unlock`
   first.

`unlock` deletes the state file only after every item is restored. If
something fails, the file stays and you can just run `unlock` again.

Restore is driven by what was recorded, not by Ubuntu's defaults:

| Recorded | On unlock |
|---|---|
| `enabled` | unmask, enable, and start if it had been running |
| `disabled` | unmask, disable — never started |
| `static` and similar | unmask only |
| `masked` | left masked; that is how it was found |
| `not-found` | skipped; the unit does not exist here |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. For `status`: locked and consistent. |
| 1 | For `status`: not locked. Not an error. |
| 2 | For `status`: locked but drifted — run `enforce`. |
| 3 | Usage error, missing privileges, or a failed operation. |

## Deliberately out of scope

- **`snapd.snap-repair.timer` is never touched.** It is Canonical's
  out-of-band channel for repairing a broken snapd; disabling it risks a
  snapd you cannot recover.
- **Apps carrying their own updater** outside apt and snap — VS Code's
  built-in updater, JetBrains Toolbox, Claude Code. Anything installed *as a
  snap* (PhpStorm, Slack, Firefox) is covered.

## Tests

```bash
bash tests/run-tests.sh
```

86 assertions, plain bash, no dependencies. `tests/fake-bin/` provides stub
`systemctl` and `snap` binaries and the script takes `UL_STATE_DIR` /
`UL_APT_CONF_DIR` overrides, so the suite never touches the host.

## Uninstall

```bash
sudo ./uninstall.sh
```

It unlocks first if the system is locked, so it can never leave a frozen
machine with no tool left to unfreeze it.

## Requirements

Ubuntu 22.04+ (built and verified on 22.04.5 LTS), bash 5, systemd, and
optionally snapd. No other runtime dependencies — not even `jq`.
