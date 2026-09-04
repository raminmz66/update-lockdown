#!/usr/bin/env bash
# Plain-bash test runner for update-lockdown. No external dependencies.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$'\t'
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }

assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not found in output" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "[$3] should not appear" ;; *) ok "$1" ;; esac; }
exists()          { [ -e "$1" ] && echo yes || echo no; }

setup() {
  WORK="$(mktemp -d)"
  export UL_STATE_DIR="$WORK/state"
  export UL_APT_CONF_DIR="$WORK/apt"
  export UL_ALLOW_NONROOT=1
  export UL_FAKE_LOG="$WORK/calls.log"
  export UL_FAKE_STATE="$WORK/units.tsv"
  export UL_FAKE_SNAP_HOLD="$WORK/snaphold"
  export PATH="$ROOT/tests/fake-bin:$PATH"
  mkdir -p "$UL_APT_CONF_DIR"
  : > "$UL_FAKE_LOG"
  : > "$UL_FAKE_SNAP_HOLD"
  {
    printf '%s\tenabled\tactive\n' \
      apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service \
      fwupd-refresh.timer update-notifier-download.timer \
      update-notifier-motd.timer motd-news.timer
    printf '%s\tstatic\tinactive\n' \
      apt-daily.service apt-daily-upgrade.service \
      packagekit-offline-update.service apt-news.service
  } > "$UL_FAKE_STATE"
}

teardown() { rm -rf "$WORK"; }

ul() { "$ROOT/update-lockdown" "$@" 2>&1; }

echo "== Task 1: skeleton =="
setup
out="$(ul --version)"; assert_contains "--version prints a version" "$out" "update-lockdown 1."
out="$(ul --help)";    assert_contains "--help documents lock"      "$out" "update-lockdown lock"
out="$(ul --help)";    assert_contains "--help documents unlock"    "$out" "update-lockdown unlock"
out="$(ul --help)";    assert_contains "--help documents status"    "$out" "update-lockdown status"
out="$(ul --help)";    assert_contains "--help documents enforce"   "$out" "update-lockdown enforce"
ul bogus >/dev/null 2>&1; assert_eq "unknown verb exits 3" "$?" "3"
ul >/dev/null 2>&1;       assert_eq "no verb exits 3"      "$?" "3"
teardown

echo "== Task 2: state primitives =="
setup
ul lock >/dev/null 2>&1 || true
assert_eq "state file created" "$(exists "$UL_STATE_DIR/state.tsv")" "yes"
st="$(cat "$UL_STATE_DIR/state.tsv" 2>/dev/null || true)"
assert_contains "schema recorded"            "$st" "schema${T}1"
assert_contains "enabled timer snapshotted"  "$st" "unit${T}apt-daily.timer${T}enabled${T}active"
assert_contains "static service snapshotted" "$st" "unit${T}apt-news.service${T}static${T}inactive"
assert_contains "apt dropin recorded absent" "$st" "aptconf${T}99-update-lockdown${T}absent"
assert_contains "snap hold recorded unset"   "$st" "snap${T}refresh.hold${T}__unset__"
assert_eq "state file is mode 0600" "$(stat -c '%a' "$UL_STATE_DIR/state.tsv" 2>/dev/null)" "600"
assert_eq "state dir is mode 0700"  "$(stat -c '%a' "$UL_STATE_DIR" 2>/dev/null)" "700"
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
