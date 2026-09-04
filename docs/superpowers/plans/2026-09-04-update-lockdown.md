# update-lockdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single bash CLI that reversibly freezes every background update mechanism on Ubuntu 22.04 and re-asserts that freeze at boot.

**Architecture:** One self-contained script at `/usr/local/bin/update-lockdown` with four verbs (`lock`, `unlock`, `status`, `enforce`). It snapshots the prior state of eleven systemd units, one apt drop-in, and the snapd `refresh.hold` option into a tab-separated state file, writes that file *before* mutating anything, and restores from it on unlock. A oneshot systemd unit runs `enforce` at boot.

**Tech Stack:** bash 5.1, systemd 249, snapd 2.76.2, coreutils. No `jq`, no `bats`, no `shellcheck` — none are installed on the target and none may become dependencies.

**Spec:** `docs/superpowers/specs/2026-09-04-update-lockdown-design.md`

## Global Constraints

- Target: Ubuntu 22.04.5 LTS, bash 5.1.16, snapd 2.76.2.
- No runtime dependency outside coreutils, systemd and snapd.
- State file: `/var/lib/update-lockdown/state.tsv`, mode `0600`, tab-separated.
- Path overrides for tests: `UL_STATE_DIR`, `UL_APT_CONF_DIR`, `UL_ALLOW_NONROOT`.
- The snapshot is written to disk **before** any mutation.
- `lock` must refuse to run when a state file already exists.
- Manual `apt upgrade` / `snap refresh` must keep working when locked.
- `snapd.snap-repair.timer` is never touched.
- Exit codes: 0 success/locked-clean, 1 status-unlocked, 2 status-drifted, 3 error.
- Every task ends with a commit on `main`.

---

### Task 1: Test harness and script skeleton

**Files:**
- Create: `update-lockdown`
- Create: `tests/fake-bin/systemctl`, `tests/fake-bin/snap`
- Create: `tests/run-tests.sh`

**Interfaces:**
- Produces: `MANAGED_UNITS` array; `log/warn/die/try/need_root`; `main` dispatching `lock|unlock|status|enforce`; env overrides `UL_STATE_DIR`, `UL_APT_CONF_DIR`, `UL_ALLOW_NONROOT`.
- Fake binaries read fixtures from `$UL_FAKE_STATE` (tsv: `unit<TAB>enabled<TAB>active`) and `$UL_FAKE_SNAP_HOLD`, and append every invocation to `$UL_FAKE_LOG`.

- [ ] **Step 1: Write the failing test** — `tests/run-tests.sh`

```bash
#!/usr/bin/env bash
# Plain-bash test runner. No external deps.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
assert_eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$3] not found in output";; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "[$3] should not appear";; *) ok "$1";; esac; }

setup() {
  WORK="$(mktemp -d)"
  export UL_STATE_DIR="$WORK/state" UL_APT_CONF_DIR="$WORK/apt" UL_ALLOW_NONROOT=1
  export UL_FAKE_LOG="$WORK/calls.log" UL_FAKE_STATE="$WORK/units.tsv"
  export UL_FAKE_SNAP_HOLD="$WORK/snaphold"
  export PATH="$ROOT/tests/fake-bin:$PATH"
  mkdir -p "$UL_APT_CONF_DIR"; : > "$UL_FAKE_LOG"; : > "$UL_FAKE_SNAP_HOLD"
  cat > "$UL_FAKE_STATE" <<'FIX'
apt-daily.timer	enabled	active
apt-daily-upgrade.timer	enabled	active
apt-daily.service	static	inactive
apt-daily-upgrade.service	static	inactive
unattended-upgrades.service	enabled	active
fwupd-refresh.timer	enabled	active
packagekit-offline-update.service	static	inactive
update-notifier-download.timer	enabled	active
update-notifier-motd.timer	enabled	active
motd-news.timer	enabled	active
apt-news.service	static	inactive
FIX
}
teardown() { rm -rf "$WORK"; }
ul() { "$ROOT/update-lockdown" "$@" 2>&1; }

echo "== Task 1: skeleton =="
setup
out="$(ul --version)";  assert_contains "--version prints a version" "$out" "update-lockdown"
out="$(ul --help)";     assert_contains "--help lists lock"   "$out" "lock"
out="$(ul --help)";     assert_contains "--help lists enforce" "$out" "enforce"
ul bogus >/dev/null 2>&1; assert_eq "unknown verb exits 3" "$?" "3"
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `update-lockdown` does not exist yet.

- [ ] **Step 3: Write the fake binaries**

`tests/fake-bin/systemctl`:

```bash
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$UL_FAKE_LOG"
cmd="${1:-}"; shift || true
lookup() { awk -F'\t' -v u="$1" -v f="$2" '$1==u{print $f}' "$UL_FAKE_STATE"; }
case "$cmd" in
  is-enabled)
    v="$(lookup "$1" 2)"
    [ -z "$v" ] || [ "$v" = not-found ] && exit 1
    echo "$v"
    case "$v" in enabled|static|indirect|enabled-runtime|generated) exit 0;; *) exit 1;; esac ;;
  is-active)
    v="$(lookup "$1" 3)"
    [ -z "$v" ] && { echo inactive; exit 3; }
    echo "$v"; [ "$v" = active ] && exit 0 || exit 3 ;;
  *) exit 0 ;;
esac
```

`tests/fake-bin/snap`:

```bash
#!/usr/bin/env bash
printf 'snap %s\n' "$*" >> "$UL_FAKE_LOG"
case "${1:-} ${2:-}" in
  "get system")
    [ "${3:-}" = refresh.hold ] || exit 1
    v="$(cat "$UL_FAKE_SNAP_HOLD" 2>/dev/null || true)"
    [ -z "$v" ] && { echo 'error: no "refresh.hold" configuration option' >&2; exit 1; }
    echo "$v" ;;
  "set system")   printf '%s' "${3#refresh.hold=}" > "$UL_FAKE_SNAP_HOLD" ;;
  "unset system") : > "$UL_FAKE_SNAP_HOLD" ;;
  *) exit 0 ;;
esac
```

`chmod +x tests/fake-bin/*`

- [ ] **Step 4: Write the minimal skeleton** — `update-lockdown`

```bash
#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
UL_STATE_DIR="${UL_STATE_DIR:-/var/lib/update-lockdown}"
UL_APT_CONF_DIR="${UL_APT_CONF_DIR:-/etc/apt/apt.conf.d}"
STATE_FILE="$UL_STATE_DIR/state.tsv"
BACKUP_DIR="$UL_STATE_DIR/backup"
APT_DROPIN="99-update-lockdown"
DRY_RUN=0; QUIET=0; FAILED=0

MANAGED_UNITS=(
  apt-daily.timer apt-daily-upgrade.timer
  apt-daily.service apt-daily-upgrade.service
  unattended-upgrades.service
  fwupd-refresh.timer
  packagekit-offline-update.service
  update-notifier-download.timer update-notifier-motd.timer
  motd-news.timer apt-news.service
)

log()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 3; }

try() {
  if [ "$DRY_RUN" -eq 1 ]; then log "  dry-run: $*"; return 0; fi
  if ! "$@" >/dev/null 2>&1; then warn "command failed: $*"; FAILED=$((FAILED+1)); return 1; fi
  return 0
}

need_root() {
  [ "${UL_ALLOW_NONROOT:-0}" = "1" ] && return 0
  [ "$(id -u)" -eq 0 ] || die "must be run as root (try: sudo update-lockdown $1)"
}

usage() {
  cat <<EOF
update-lockdown $VERSION — reversibly freeze background system updates

USAGE
  sudo update-lockdown lock      Snapshot current state, then freeze updates
  sudo update-lockdown unlock    Restore the snapshot exactly, then forget it
       update-lockdown status    Report every managed item
  sudo update-lockdown enforce   Re-apply the frozen state (used at boot)

OPTIONS
  --dry-run   Print every action without changing anything
  --quiet     Suppress informational output
  --help      Show this help
  --version   Show the version

EXIT CODES
  0 success, or status: locked and consistent
  1 status: not locked
  2 status: locked but drifted
  3 usage error, missing privileges, or a failed operation
EOF
}

main() {
  local verb="" args=()
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=1 ;;
      --quiet)   QUIET=1 ;;
      --help|-h) usage; exit 0 ;;
      --version|-V) printf 'update-lockdown %s\n' "$VERSION"; exit 0 ;;
      -*) die "unknown option: $a" ;;
      *) args+=("$a") ;;
    esac
  done
  [ "${#args[@]}" -gt 0 ] || { usage; exit 3; }
  verb="${args[0]}"
  case "$verb" in
    lock)    cmd_lock ;;
    unlock)  cmd_unlock ;;
    status)  cmd_status ;;
    enforce) cmd_enforce ;;
    *) die "unknown command: $verb" ;;
  esac
}

cmd_lock()    { die "not implemented"; }
cmd_unlock()  { die "not implemented"; }
cmd_status()  { die "not implemented"; }
cmd_enforce() { die "not implemented"; }

main "$@"
```

`chmod +x update-lockdown`

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run-tests.sh`
Expected: `4 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
git add update-lockdown tests/
git commit -m "Add update-lockdown skeleton and plain-bash test harness"
```

---

### Task 2: State file primitives

**Files:**
- Modify: `update-lockdown`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Produces: `unit_enabled_state <unit>` → `enabled|disabled|masked|static|indirect|enabled-runtime|generated|not-found`; `unit_active_state <unit>` → `active|inactive`; `snap_hold_value` → value or `__unset__`; `state_write`; `state_each_unit` (emits `name<TAB>enabled<TAB>active` per line); `state_field <kind> <key>`; `is_locked`.

- [ ] **Step 1: Write the failing test** — append to `tests/run-tests.sh` before the summary

```bash
echo "== Task 2: state primitives =="
setup
ul lock >/dev/null 2>&1 || true
assert_eq "state file created" "$([ -f "$UL_STATE_DIR/state.tsv" ] && echo yes || echo no)" "yes"
s="$(cat "$UL_STATE_DIR/state.tsv")"
assert_contains "schema recorded"      "$s" "schema	1"
assert_contains "enabled timer snapshotted" "$s" "unit	apt-daily.timer	enabled	active"
assert_contains "static service snapshotted" "$s" "unit	apt-news.service	static	inactive"
assert_contains "apt dropin absent"    "$s" "aptconf	99-update-lockdown	absent"
assert_contains "snap hold unset"      "$s" "snap	refresh.hold	__unset__"
assert_eq "state file is 0600" "$(stat -c '%a' "$UL_STATE_DIR/state.tsv")" "600"
teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — no state file; `cmd_lock` still dies.

- [ ] **Step 3: Implement the primitives** — insert above the `cmd_*` stubs

```bash
unit_enabled_state() {
  local out; out="$(systemctl is-enabled "$1" 2>/dev/null || true)"
  out="${out%%$'\n'*}"
  [ -n "$out" ] || out="not-found"
  printf '%s' "$out"
}

unit_active_state() {
  local out; out="$(systemctl is-active "$1" 2>/dev/null || true)"
  out="${out%%$'\n'*}"
  [ "$out" = "active" ] && printf 'active' || printf 'inactive'
}

snap_hold_value() {
  local v; v="$(snap get system refresh.hold 2>/dev/null || true)"
  v="${v%%$'\n'*}"
  [ -n "$v" ] && printf '%s' "$v" || printf '__unset__'
}

is_locked() { [ -f "$STATE_FILE" ]; }

state_write() {
  local tmp
  mkdir -p "$UL_STATE_DIR"; chmod 700 "$UL_STATE_DIR"
  tmp="$STATE_FILE.tmp.$$"
  {
    printf '#update-lockdown state — do not edit by hand\n'
    printf 'schema\t1\n'
    printf 'locked_at\t%s\n' "$(date -Is)"
    local u
    for u in "${MANAGED_UNITS[@]}"; do
      printf 'unit\t%s\t%s\t%s\n' "$u" "$(unit_enabled_state "$u")" "$(unit_active_state "$u")"
    done
    if [ -e "$UL_APT_CONF_DIR/$APT_DROPIN" ]; then
      printf 'aptconf\t%s\tpresent\n' "$APT_DROPIN"
    else
      printf 'aptconf\t%s\tabsent\n' "$APT_DROPIN"
    fi
    printf 'snap\trefresh.hold\t%s\n' "$(snap_hold_value)"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

state_each_unit() {
  local kind a b c
  while IFS=$'\t' read -r kind a b c; do
    [ "$kind" = "unit" ] || continue
    printf '%s\t%s\t%s\n' "$a" "$b" "$c"
  done < "$STATE_FILE"
}

state_field() {
  local kind a b c
  while IFS=$'\t' read -r kind a b c; do
    if [ "$kind" = "$1" ] && [ "$a" = "$2" ]; then printf '%s' "$b"; return 0; fi
  done < "$STATE_FILE"
  return 1
}
```

Replace the `cmd_lock` stub with a snapshot-only version for now:

```bash
cmd_lock() {
  need_root lock
  is_locked && die "already locked — run 'update-lockdown unlock' first"
  [ "$DRY_RUN" -eq 1 ] || state_write
  log "snapshot written to $STATE_FILE"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-tests.sh`
Expected: all Task 1 and Task 2 assertions pass.

- [ ] **Step 5: Commit**

```bash
git add update-lockdown tests/run-tests.sh
git commit -m "Add state snapshot primitives and tab-separated state file"
```

---

### Task 3: Freeze systemd units

**Files:**
- Modify: `update-lockdown`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `MANAGED_UNITS`, `unit_enabled_state`, `try`, `state_each_unit`.
- Produces: `freeze_units_from_state` — masks every unit named in the state file, calling `disable` only for units recorded `enabled`.

- [ ] **Step 1: Write the failing test**

```bash
echo "== Task 3: freeze units =="
setup
ul lock >/dev/null 2>&1
calls="$(cat "$UL_FAKE_LOG")"
assert_contains "masks enabled timer"   "$calls" "systemctl mask apt-daily.timer"
assert_contains "stops enabled timer"   "$calls" "systemctl stop apt-daily.timer"
assert_contains "disables enabled unit" "$calls" "systemctl disable unattended-upgrades.service"
assert_contains "masks static unit"     "$calls" "systemctl mask apt-news.service"
assert_absent   "never disables static" "$calls" "systemctl disable apt-news.service"
assert_absent   "never touches snap-repair" "$calls" "snap-repair"
teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — no `systemctl mask` calls logged.

- [ ] **Step 3: Implement**

```bash
freeze_units_from_state() {
  local name prior active
  while IFS=$'\t' read -r name prior active; do
    [ "$prior" = "not-found" ] && continue
    [ "$prior" = "masked" ] && continue
    log "  freezing $name (was $prior/$active)"
    try systemctl stop "$name" || true
    [ "$prior" = "enabled" ] && { try systemctl disable "$name" || true; }
    try systemctl mask "$name" || true
  done < <(state_each_unit)
}
```

Extend `cmd_lock`:

```bash
cmd_lock() {
  need_root lock
  is_locked && die "already locked — run 'update-lockdown unlock' first"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: would snapshot to $STATE_FILE, then freeze"
    return 0
  fi
  state_write
  log "snapshot written to $STATE_FILE"
  freeze_units_from_state
  try systemctl daemon-reload || true
  [ "$FAILED" -eq 0 ] || die "$FAILED operation(s) failed"
  log "updates locked down."
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-tests.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add update-lockdown tests/run-tests.sh
git commit -m "Freeze managed systemd units on lock"
```

---

### Task 4: Restore systemd units

**Files:**
- Modify: `update-lockdown`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Produces: `restore_units_from_state`; `cmd_unlock` deleting the state file only on full success.

- [ ] **Step 1: Write the failing test**

```bash
echo "== Task 4: restore units =="
setup
ul lock >/dev/null 2>&1
: > "$UL_FAKE_LOG"
ul unlock >/dev/null 2>&1
calls="$(cat "$UL_FAKE_LOG")"
assert_contains "unmasks enabled timer" "$calls" "systemctl unmask apt-daily.timer"
assert_contains "re-enables it"         "$calls" "systemctl enable apt-daily.timer"
assert_contains "restarts active timer" "$calls" "systemctl start apt-daily.timer"
assert_contains "unmasks static unit"   "$calls" "systemctl unmask apt-news.service"
assert_absent   "never enables static"  "$calls" "systemctl enable apt-news.service"
assert_absent   "never starts inactive" "$calls" "systemctl start apt-news.service"
assert_eq "state file removed" "$([ -f "$UL_STATE_DIR/state.tsv" ] && echo yes || echo no)" "no"
out="$(ul unlock)"; assert_contains "unlock when unlocked is benign" "$out" "not locked"
teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `cmd_unlock` still dies with "not implemented".

- [ ] **Step 3: Implement**

```bash
restore_units_from_state() {
  local name prior active
  while IFS=$'\t' read -r name prior active; do
    case "$prior" in
      not-found) continue ;;
      masked)    log "  $name was masked before lockdown — leaving masked"; continue ;;
    esac
    log "  restoring $name to $prior/$active"
    try systemctl unmask "$name" || true
    case "$prior" in
      enabled)  try systemctl enable "$name" || true ;;
      disabled) try systemctl disable "$name" || true ;;
    esac
    [ "$active" = "active" ] && { try systemctl start "$name" || true; }
  done < <(state_each_unit)
}

cmd_unlock() {
  need_root unlock
  if ! is_locked; then log "not locked — nothing to restore."; return 0; fi
  if [ "$DRY_RUN" -eq 1 ]; then log "dry-run: would restore from $STATE_FILE"; return 0; fi
  restore_units_from_state
  try systemctl daemon-reload || true
  if [ "$FAILED" -ne 0 ]; then
    die "$FAILED operation(s) failed — state file kept, re-run 'update-lockdown unlock'"
  fi
  rm -f "$STATE_FILE"
  log "updates restored to their pre-lockdown state."
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-tests.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add update-lockdown tests/run-tests.sh
git commit -m "Restore systemd units exactly on unlock"
```

---

### Task 5: apt drop-in

**Files:**
- Modify: `update-lockdown`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Produces: `freeze_apt`, `restore_apt`. Never modifies `10periodic`.

- [ ] **Step 1: Write the failing test**

```bash
echo "== Task 5: apt drop-in =="
setup
printf 'APT::Periodic::Update-Package-Lists "0";\n' > "$UL_APT_CONF_DIR/10periodic"
before="$(cat "$UL_APT_CONF_DIR/10periodic")"
ul lock >/dev/null 2>&1
assert_eq "dropin created" "$([ -f "$UL_APT_CONF_DIR/99-update-lockdown" ] && echo yes || echo no)" "yes"
assert_contains "dropin disables periodic" "$(cat "$UL_APT_CONF_DIR/99-update-lockdown")" 'APT::Periodic::Enable "0";'
assert_eq "10periodic untouched" "$(cat "$UL_APT_CONF_DIR/10periodic")" "$before"
ul unlock >/dev/null 2>&1
assert_eq "dropin removed" "$([ -f "$UL_APT_CONF_DIR/99-update-lockdown" ] && echo yes || echo no)" "no"
teardown

setup
printf 'pre-existing\n' > "$UL_APT_CONF_DIR/99-update-lockdown"
ul lock >/dev/null 2>&1
ul unlock >/dev/null 2>&1
assert_eq "pre-existing dropin restored" "$(cat "$UL_APT_CONF_DIR/99-update-lockdown")" "pre-existing"
teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — drop-in never created.

- [ ] **Step 3: Implement**

```bash
freeze_apt() {
  local target="$UL_APT_CONF_DIR/$APT_DROPIN"
  if [ -e "$target" ] && [ "$(state_field aptconf "$APT_DROPIN")" = "present" ]; then
    mkdir -p "$BACKUP_DIR"
    cp -a "$target" "$BACKUP_DIR/$APT_DROPIN"
    log "  backed up existing $APT_DROPIN"
  fi
  log "  writing $target"
  [ "$DRY_RUN" -eq 1 ] && return 0
  mkdir -p "$UL_APT_CONF_DIR"
  cat > "$target" <<'EOF'
// Written by update-lockdown. Removed automatically by `update-lockdown unlock`.
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::AutocleanInterval "0";
EOF
  chmod 644 "$target"
}

restore_apt() {
  local target="$UL_APT_CONF_DIR/$APT_DROPIN"
  rm -f "$target"
  if [ "$(state_field aptconf "$APT_DROPIN")" = "present" ] && [ -e "$BACKUP_DIR/$APT_DROPIN" ]; then
    cp -a "$BACKUP_DIR/$APT_DROPIN" "$target"
    rm -f "$BACKUP_DIR/$APT_DROPIN"
    log "  restored the original $APT_DROPIN"
  else
    log "  removed $target"
  fi
}
```

Call `freeze_apt` in `cmd_lock` after `freeze_units_from_state`, and `restore_apt` in `cmd_unlock` after `restore_units_from_state`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-tests.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add update-lockdown tests/run-tests.sh
git commit -m "Add apt periodic drop-in with exact restore"
```

---

### Task 6: snapd refresh.hold

**Files:**
- Modify: `update-lockdown`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Produces: `freeze_snap`, `restore_snap`. Uses `refresh.hold`, never `snap refresh --hold`.

- [ ] **Step 1: Write the failing test**

```bash
echo "== Task 6: snapd hold =="
setup
ul lock >/dev/null 2>&1
assert_contains "sets hold forever" "$(cat "$UL_FAKE_LOG")" "snap set system refresh.hold=forever"
assert_eq "hold value applied" "$(cat "$UL_FAKE_SNAP_HOLD")" "forever"
assert_absent "never uses refresh --hold" "$(cat "$UL_FAKE_LOG")" "snap refresh --hold"
ul unlock >/dev/null 2>&1
assert_contains "unsets hold when it was unset" "$(cat "$UL_FAKE_LOG")" "snap unset system refresh.hold"
teardown

setup
printf '2030-01-01T00:00:00Z' > "$UL_FAKE_SNAP_HOLD"
ul lock >/dev/null 2>&1
ul unlock >/dev/null 2>&1
assert_eq "prior hold value round-trips" "$(cat "$UL_FAKE_SNAP_HOLD")" "2030-01-01T00:00:00Z"
teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — no `snap set` call logged.

- [ ] **Step 3: Implement**

```bash
freeze_snap() {
  command -v snap >/dev/null 2>&1 || { log "  snapd not present — skipping"; return 0; }
  log "  holding snap auto-refresh (manual 'snap refresh' still works)"
  try snap set system refresh.hold=forever || true
}

restore_snap() {
  command -v snap >/dev/null 2>&1 || return 0
  local prior; prior="$(state_field snap refresh.hold || printf '__unset__')"
  if [ "$prior" = "__unset__" ]; then
    log "  clearing snap refresh.hold"
    try snap unset system refresh.hold || true
  else
    log "  restoring snap refresh.hold=$prior"
    try snap set system "refresh.hold=$prior" || true
  fi
}
```

Call `freeze_snap` in `cmd_lock` and `restore_snap` in `cmd_unlock`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-tests.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add update-lockdown tests/run-tests.sh
git commit -m "Hold snapd auto-refresh while leaving manual refresh working"
```

---

### Task 7: Overwrite guard and --dry-run

**Files:**
- Modify: `tests/run-tests.sh`
- Modify: `update-lockdown` only if a test exposes a defect.

**Interfaces:**
- Consumes: `cmd_lock`, `cmd_unlock`.
- Produces: proof of the two safety invariants — double-lock never overwrites a snapshot, and `--dry-run` mutates nothing.

- [ ] **Step 1: Write the failing test**

```bash
echo "== Task 7: safety invariants =="
setup
ul lock >/dev/null 2>&1
sum1="$(cksum < "$UL_STATE_DIR/state.tsv")"
ul lock >/dev/null 2>&1; rc=$?
assert_eq "second lock exits 3" "$rc" "3"
assert_eq "snapshot byte-identical" "$(cksum < "$UL_STATE_DIR/state.tsv")" "$sum1"
out="$(ul lock)"; assert_contains "second lock explains itself" "$out" "already locked"
teardown

setup
: > "$UL_FAKE_LOG"
ul lock --dry-run >/dev/null 2>&1
assert_eq "dry-run writes no state" "$([ -f "$UL_STATE_DIR/state.tsv" ] && echo yes || echo no)" "no"
assert_absent "dry-run masks nothing" "$(cat "$UL_FAKE_LOG")" "systemctl mask"
assert_absent "dry-run holds no snap" "$(cat "$UL_FAKE_LOG")" "snap set"
assert_eq "dry-run writes no dropin" "$([ -f "$UL_APT_CONF_DIR/99-update-lockdown" ] && echo yes || echo no)" "no"
teardown
```

- [ ] **Step 2: Run and inspect**

Run: `bash tests/run-tests.sh`
Expected: PASS if Tasks 2–6 were implemented correctly. Any failure here is a real defect in the guard or in `--dry-run` — fix it in `update-lockdown` before committing.

- [ ] **Step 3: Commit**

```bash
git add update-lockdown tests/run-tests.sh
git commit -m "Cover the double-lock guard and dry-run invariants"
```

---

### Task 8: status

**Files:**
- Modify: `update-lockdown`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Produces: `cmd_status` printing a per-item table and exiting 1 unlocked, 0 locked-clean, 2 locked-drifted.

- [ ] **Step 1: Write the failing test**

```bash
echo "== Task 8: status =="
setup
ul status >/dev/null 2>&1; assert_eq "unlocked exits 1" "$?" "1"
out="$(ul status)"; assert_contains "unlocked says so" "$out" "NOT LOCKED"
ul lock >/dev/null 2>&1
# fake-bin reports masked units once lock has run
sed -i 's/\tenabled\t/\tmasked\t/; s/\tstatic\t/\tmasked\t/' "$UL_FAKE_STATE"
printf 'forever' > "$UL_FAKE_SNAP_HOLD"
ul status >/dev/null 2>&1; assert_eq "locked and clean exits 0" "$?" "0"
out="$(ul status)"; assert_contains "clean status reports LOCKED" "$out" "LOCKED"
# now simulate drift: one unit came back
sed -i '1s/\tmasked\t/\tenabled\t/' "$UL_FAKE_STATE"
ul status >/dev/null 2>&1; assert_eq "drift exits 2" "$?" "2"
out="$(ul status)"; assert_contains "drift is named" "$out" "DRIFT"
teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `cmd_status` still dies.

- [ ] **Step 3: Implement**

```bash
cmd_status() {
  if ! is_locked; then
    printf 'update-lockdown: NOT LOCKED\n\nBackground updates are running normally.\nRun `sudo update-lockdown lock` to freeze them.\n'
    return 1
  fi
  local drift=0 name prior active now
  printf 'update-lockdown: LOCKED (since %s)\n\n' "$(state_field '' locked_at 2>/dev/null || printf 'unknown')"
  printf '%-38s %-12s %-12s %s\n' "ITEM" "NOW" "WAS" "RESULT"
  while IFS=$'\t' read -r name prior active; do
    [ "$prior" = "not-found" ] && continue
    now="$(unit_enabled_state "$name")"
    if [ "$now" = "masked" ] || [ "$prior" = "masked" ]; then
      printf '%-38s %-12s %-12s %s\n' "$name" "$now" "$prior" "ok"
    else
      printf '%-38s %-12s %-12s %s\n' "$name" "$now" "$prior" "DRIFT"
      drift=1
    fi
  done < <(state_each_unit)

  now="$(snap_hold_value)"
  if [ "$now" = "forever" ]; then
    printf '%-38s %-12s %-12s %s\n' "snap refresh.hold" "$now" "$(state_field snap refresh.hold)" "ok"
  else
    printf '%-38s %-12s %-12s %s\n' "snap refresh.hold" "$now" "$(state_field snap refresh.hold)" "DRIFT"
    drift=1
  fi

  if [ -e "$UL_APT_CONF_DIR/$APT_DROPIN" ]; then
    printf '%-38s %-12s %-12s %s\n' "apt $APT_DROPIN" "present" "$(state_field aptconf "$APT_DROPIN")" "ok"
  else
    printf '%-38s %-12s %-12s %s\n' "apt $APT_DROPIN" "absent" "$(state_field aptconf "$APT_DROPIN")" "DRIFT"
    drift=1
  fi

  if [ "$drift" -eq 1 ]; then
    printf '\nDrift detected. Run `sudo update-lockdown enforce` to re-apply.\n'
    return 2
  fi
  printf '\nAll managed items are frozen.\n'
  return 0
}
```

`state_field` must tolerate the metadata form `locked_at<TAB>value`; extend it so a `kind` of `''` matches a bare metadata key:

```bash
state_field() {
  local kind a b c
  while IFS=$'\t' read -r kind a b c; do
    if [ -z "$1" ] && [ "$kind" = "$2" ]; then printf '%s' "$a"; return 0; fi
    if [ "$kind" = "$1" ] && [ "$a" = "$2" ]; then printf '%s' "$b"; return 0; fi
  done < "$STATE_FILE"
  return 1
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-tests.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add update-lockdown tests/run-tests.sh
git commit -m "Add status verb with drift detection and documented exit codes"
```

---

### Task 9: enforce and the boot unit

**Files:**
- Modify: `update-lockdown`
- Create: `systemd/update-lockdown.service`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Produces: `cmd_enforce` — re-applies the frozen target for every recorded item and **never writes the state file**.

- [ ] **Step 1: Write the failing test**

```bash
echo "== Task 9: enforce =="
setup
ul lock >/dev/null 2>&1
sum1="$(cksum < "$UL_STATE_DIR/state.tsv")"
rm -f "$UL_APT_CONF_DIR/99-update-lockdown"
: > "$UL_FAKE_LOG"
ul enforce >/dev/null 2>&1; assert_eq "enforce exits 0" "$?" "0"
assert_eq "state file unchanged" "$(cksum < "$UL_STATE_DIR/state.tsv")" "$sum1"
assert_contains "enforce re-masks" "$(cat "$UL_FAKE_LOG")" "systemctl mask apt-daily.timer"
assert_eq "enforce rewrites dropin" "$([ -f "$UL_APT_CONF_DIR/99-update-lockdown" ] && echo yes || echo no)" "yes"
teardown

setup
ul enforce >/dev/null 2>&1; assert_eq "enforce without state is a silent no-op" "$?" "0"
assert_absent "enforce without state changes nothing" "$(cat "$UL_FAKE_LOG")" "systemctl mask"
teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `cmd_enforce` still dies.

- [ ] **Step 3: Implement**

```bash
cmd_enforce() {
  need_root enforce
  is_locked || { log "not locked — nothing to enforce."; return 0; }
  log "re-applying lockdown from $STATE_FILE"
  freeze_units_from_state
  freeze_apt
  freeze_snap
  try systemctl daemon-reload || true
  [ "$FAILED" -eq 0 ] || die "$FAILED operation(s) failed"
  log "lockdown enforced."
}
```

`systemd/update-lockdown.service`:

```ini
[Unit]
Description=Re-apply update lockdown
Documentation=https://github.com/raminmz66/update-lockdown
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-tests.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add update-lockdown systemd/ tests/run-tests.sh
git commit -m "Add enforce verb and boot-time systemd unit"
```

---

### Task 10: Installer and uninstaller

**Files:**
- Create: `install.sh`, `uninstall.sh`

**Interfaces:**
- `install.sh` copies the script to `/usr/local/bin`, installs and enables `update-lockdown.service`.
- `uninstall.sh` unlocks first if locked, then removes everything it installed.

- [ ] **Step 1: Write `install.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/bin/update-lockdown
UNIT=/etc/systemd/system/update-lockdown.service

[ "$(id -u)" -eq 0 ] || { echo "error: run with sudo" >&2; exit 3; }

install -m 0755 "$SRC/update-lockdown" "$BIN"
install -m 0644 "$SRC/systemd/update-lockdown.service" "$UNIT"
systemctl daemon-reload
systemctl enable update-lockdown.service

cat <<EOF

Installed:
  $BIN
  $UNIT  (enabled — re-applies the lockdown at every boot)

Next steps:
  sudo update-lockdown lock      freeze background updates
       update-lockdown status    check what is frozen
  sudo update-lockdown unlock    put everything back

The boot unit does nothing until you run 'lock' at least once.
EOF
```

- [ ] **Step 2: Write `uninstall.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
BIN=/usr/local/bin/update-lockdown
UNIT=/etc/systemd/system/update-lockdown.service

[ "$(id -u)" -eq 0 ] || { echo "error: run with sudo" >&2; exit 3; }

if [ -f /var/lib/update-lockdown/state.tsv ] && [ -x "$BIN" ]; then
  echo "System is locked — restoring updates before uninstalling."
  "$BIN" unlock
fi

systemctl disable --now update-lockdown.service 2>/dev/null || true
rm -f "$UNIT" "$BIN"
rmdir /var/lib/update-lockdown 2>/dev/null || true
systemctl daemon-reload
echo "update-lockdown removed. Background updates are running normally."
```

`chmod +x install.sh uninstall.sh`

- [ ] **Step 3: Verify both parse**

Run: `bash -n install.sh && bash -n uninstall.sh && echo "syntax ok"`
Expected: `syntax ok`

- [ ] **Step 4: Commit**

```bash
git add install.sh uninstall.sh
git commit -m "Add installer that enables the boot unit, and a safe uninstaller"
```

---

### Task 11: README and end-to-end verification

**Files:**
- Create: `README.md`, `.gitignore`

**Interfaces:** none — documentation and the final gate.

- [ ] **Step 1: Write `README.md`**

Must cover: what it does and the exact list of frozen mechanisms; the background-only guarantee (manual `apt upgrade` / `snap refresh` still work); install; the four commands; how the boot unit works; the state file and the double-lock guard; exit codes; what is deliberately out of scope (`snapd.snap-repair.timer`, self-updating apps); how to run the tests; uninstall.

- [ ] **Step 2: Run the full suite**

Run: `bash tests/run-tests.sh`
Expected: every assertion passes, exit 0.

- [ ] **Step 3: Real dry-run on the host**

Run: `sudo ./update-lockdown lock --dry-run`
Expected: lists intended actions; creates no state file, masks nothing.
Verify: `[ ! -f /var/lib/update-lockdown/state.tsv ] && echo "clean"`

- [ ] **Step 4: Real install and lock**

```bash
sudo ./install.sh
sudo update-lockdown lock
update-lockdown status
systemctl is-enabled apt-daily.timer unattended-upgrades.service   # expect: masked
snap refresh --time                                                # expect: hold: forever
systemctl is-enabled update-lockdown.service                       # expect: enabled
```

- [ ] **Step 5: Commit**

```bash
git add README.md .gitignore
git commit -m "Add README and finish end-to-end verification"
```

---

## Self-Review

**Spec coverage.** Interface → Task 1. State model, ordering rule → Task 2. Overwrite guard → Tasks 2 and 7. systemd freeze/restore table → Tasks 3 and 4. apt drop-in incl. pre-existing-file case → Task 5. snapd `refresh.hold` both branches → Task 6. `--dry-run` → Task 7. `status` exit codes 0/1/2 → Task 8. `enforce` + boot unit → Task 9. Repository layout, install → Tasks 9–11. Out-of-scope notes (`snap-repair`, self-updaters) → README, Task 11. Test coverage items 1–9 from the spec map to Tasks 2,3,7,4,5,6,9,8,7 respectively. No gaps.

**Placeholders.** None — every code step carries the real code.

**Type consistency.** `state_each_unit` emits three tab-separated fields and is consumed with the same `name prior active` triple in Tasks 3, 4 and 8. `state_field` gains its metadata branch in Task 8, the only caller needing it. `try` returns non-zero on failure and every call site appends `|| true` so `set -e` cannot abort a partial apply. `MANAGED_UNITS` is written once in Task 1 and only ever read afterwards.
