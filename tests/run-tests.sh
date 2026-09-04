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

echo "== Task 3: freeze units =="
setup
ul lock >/dev/null 2>&1
calls="$(cat "$UL_FAKE_LOG")"
assert_contains "masks an enabled timer"    "$calls" "systemctl mask apt-daily.timer"
assert_contains "stops an enabled timer"    "$calls" "systemctl stop apt-daily.timer"
assert_contains "disables an enabled unit"  "$calls" "systemctl disable unattended-upgrades.service"
assert_contains "masks a static unit"       "$calls" "systemctl mask apt-news.service"
assert_absent   "never disables a static unit" "$calls" "systemctl disable apt-news.service"
assert_absent   "never touches snap-repair" "$calls" "snap-repair"
assert_contains "reloads systemd"           "$calls" "systemctl daemon-reload"
teardown

echo "== Task 4: restore units =="
setup
ul lock >/dev/null 2>&1
: > "$UL_FAKE_LOG"
ul unlock >/dev/null 2>&1
calls="$(cat "$UL_FAKE_LOG")"
assert_contains "unmasks an enabled timer"  "$calls" "systemctl unmask apt-daily.timer"
assert_contains "re-enables it"             "$calls" "systemctl enable apt-daily.timer"
assert_contains "restarts an active timer"  "$calls" "systemctl start apt-daily.timer"
assert_contains "unmasks a static unit"     "$calls" "systemctl unmask apt-news.service"
assert_absent   "never enables a static unit" "$calls" "systemctl enable apt-news.service"
assert_absent   "never starts an inactive unit" "$calls" "systemctl start apt-news.service"
assert_eq "state file removed after unlock" "$(exists "$UL_STATE_DIR/state.tsv")" "no"
out="$(ul unlock)"
assert_contains "unlock when unlocked is benign" "$out" "not locked"
ul unlock >/dev/null 2>&1; assert_eq "unlock when unlocked exits 0" "$?" "0"
teardown

echo "== Task 4b: masked and missing units round-trip =="
setup
printf 'fwupd-refresh.timer\tmasked\tinactive\n' >> "$UL_FAKE_STATE"
sed -i '/^fwupd-refresh.timer\tenabled/d' "$UL_FAKE_STATE"
sed -i '/^motd-news.timer\t/d' "$UL_FAKE_STATE"
ul lock >/dev/null 2>&1
st="$(cat "$UL_STATE_DIR/state.tsv")"
assert_contains "absent unit recorded not-found" "$st" "unit${T}motd-news.timer${T}not-found"
: > "$UL_FAKE_LOG"
ul unlock >/dev/null 2>&1
calls="$(cat "$UL_FAKE_LOG")"
assert_absent "pre-masked unit stays masked"  "$calls" "systemctl unmask fwupd-refresh.timer"
assert_absent "absent unit is skipped"        "$calls" "systemctl unmask motd-news.timer"
teardown

echo "== Task 5: apt drop-in =="
setup
printf 'APT::Periodic::Update-Package-Lists "0";\n' > "$UL_APT_CONF_DIR/10periodic"
before="$(cat "$UL_APT_CONF_DIR/10periodic")"
ul lock >/dev/null 2>&1
assert_eq "dropin created" "$(exists "$UL_APT_CONF_DIR/99-update-lockdown")" "yes"
assert_contains "dropin disables periodic" "$(cat "$UL_APT_CONF_DIR/99-update-lockdown")" 'APT::Periodic::Enable "0";'
assert_eq "10periodic left untouched" "$(cat "$UL_APT_CONF_DIR/10periodic")" "$before"
ul unlock >/dev/null 2>&1
assert_eq "dropin removed on unlock" "$(exists "$UL_APT_CONF_DIR/99-update-lockdown")" "no"
assert_eq "10periodic still untouched" "$(cat "$UL_APT_CONF_DIR/10periodic")" "$before"
teardown

echo "== Task 5b: pre-existing drop-in is preserved =="
setup
printf 'pre-existing content\n' > "$UL_APT_CONF_DIR/99-update-lockdown"
ul lock >/dev/null 2>&1
assert_contains "lock records it as present" "$(cat "$UL_STATE_DIR/state.tsv")" "aptconf${T}99-update-lockdown${T}present"
assert_contains "lock overwrote it" "$(cat "$UL_APT_CONF_DIR/99-update-lockdown")" 'APT::Periodic::Enable "0";'
ul unlock >/dev/null 2>&1
assert_eq "unlock restores the original" "$(cat "$UL_APT_CONF_DIR/99-update-lockdown")" "pre-existing content"
teardown

echo "== Task 6: snapd hold =="
setup
ul lock >/dev/null 2>&1
calls="$(cat "$UL_FAKE_LOG")"
assert_contains "sets hold to forever" "$calls" "snap set system refresh.hold=forever"
assert_eq "hold value applied" "$(cat "$UL_FAKE_SNAP_HOLD")" "forever"
assert_absent "never uses 'snap refresh --hold'" "$calls" "snap refresh --hold"
ul unlock >/dev/null 2>&1
assert_contains "unsets hold when it was unset" "$(cat "$UL_FAKE_LOG")" "snap unset system refresh.hold"
assert_eq "hold cleared" "$(cat "$UL_FAKE_SNAP_HOLD")" ""
teardown

echo "== Task 6b: a pre-existing hold round-trips =="
setup
printf '2030-01-01T00:00:00Z' > "$UL_FAKE_SNAP_HOLD"
ul lock >/dev/null 2>&1
assert_contains "prior hold snapshotted" "$(cat "$UL_STATE_DIR/state.tsv")" "snap${T}refresh.hold${T}2030-01-01T00:00:00Z"
assert_eq "lock still applies forever" "$(cat "$UL_FAKE_SNAP_HOLD")" "forever"
ul unlock >/dev/null 2>&1
assert_eq "prior hold value restored" "$(cat "$UL_FAKE_SNAP_HOLD")" "2030-01-01T00:00:00Z"
teardown

echo "== Task 7: safety invariants =="
setup
ul lock >/dev/null 2>&1
sum1="$(cksum < "$UL_STATE_DIR/state.tsv")"
ul lock >/dev/null 2>&1; rc=$?
assert_eq "a second lock exits 3" "$rc" "3"
assert_eq "snapshot left byte-identical" "$(cksum < "$UL_STATE_DIR/state.tsv")" "$sum1"
out="$(ul lock 2>&1)"; assert_contains "second lock explains itself" "$out" "already locked"
teardown

echo "== Task 7b: --dry-run mutates nothing =="
setup
ul lock --dry-run >/dev/null 2>&1; assert_eq "dry-run lock exits 0" "$?" "0"
assert_eq "dry-run writes no state file" "$(exists "$UL_STATE_DIR/state.tsv")" "no"
assert_eq "dry-run writes no dropin"     "$(exists "$UL_APT_CONF_DIR/99-update-lockdown")" "no"
calls="$(cat "$UL_FAKE_LOG")"
assert_absent "dry-run masks nothing"    "$calls" "systemctl mask"
assert_absent "dry-run stops nothing"    "$calls" "systemctl stop"
assert_absent "dry-run holds no snap"    "$calls" "snap set"
out="$(ul lock --dry-run)"
assert_contains "dry-run reports its plan" "$out" "would mask apt-daily.timer"
teardown

echo "== Task 7c: --dry-run unlock mutates nothing =="
setup
ul lock >/dev/null 2>&1
sum1="$(cksum < "$UL_STATE_DIR/state.tsv")"
: > "$UL_FAKE_LOG"
ul unlock --dry-run >/dev/null 2>&1
assert_eq "dry-run unlock keeps the state file" "$(exists "$UL_STATE_DIR/state.tsv")" "yes"
assert_eq "state file unchanged" "$(cksum < "$UL_STATE_DIR/state.tsv")" "$sum1"
assert_absent "dry-run unlock unmasks nothing" "$(cat "$UL_FAKE_LOG")" "systemctl unmask"
teardown

echo "== Task 8: status =="
setup
ul status >/dev/null 2>&1; assert_eq "unlocked exits 1" "$?" "1"
out="$(ul status)"; assert_contains "unlocked says NOT LOCKED" "$out" "NOT LOCKED"
ul lock >/dev/null 2>&1
# the fake systemctl now reports every managed unit as masked, as a real
# system would after a lock
sed -i "s/${T}enabled${T}/${T}masked${T}/; s/${T}static${T}/${T}masked${T}/" "$UL_FAKE_STATE"
ul status >/dev/null 2>&1; assert_eq "locked and clean exits 0" "$?" "0"
out="$(ul status)"
assert_contains "clean status says LOCKED"   "$out" "LOCKED"
assert_contains "clean status lists a unit"  "$out" "apt-daily.timer"
assert_contains "clean status shows the snap hold" "$out" "refresh.hold"
assert_absent   "clean status reports no drift" "$out" "DRIFT"
teardown

echo "== Task 8b: drift is detected =="
setup
ul lock >/dev/null 2>&1
sed -i "s/${T}enabled${T}/${T}masked${T}/; s/${T}static${T}/${T}masked${T}/" "$UL_FAKE_STATE"
sed -i "1s/${T}masked${T}/${T}enabled${T}/" "$UL_FAKE_STATE"
ul status >/dev/null 2>&1; assert_eq "unit drift exits 2" "$?" "2"
out="$(ul status)"; assert_contains "unit drift is named" "$out" "DRIFT"
teardown

setup
ul lock >/dev/null 2>&1
sed -i "s/${T}enabled${T}/${T}masked${T}/; s/${T}static${T}/${T}masked${T}/" "$UL_FAKE_STATE"
: > "$UL_FAKE_SNAP_HOLD"
ul status >/dev/null 2>&1; assert_eq "snap drift exits 2" "$?" "2"
teardown

setup
ul lock >/dev/null 2>&1
sed -i "s/${T}enabled${T}/${T}masked${T}/; s/${T}static${T}/${T}masked${T}/" "$UL_FAKE_STATE"
rm -f "$UL_APT_CONF_DIR/99-update-lockdown"
ul status >/dev/null 2>&1; assert_eq "apt drift exits 2" "$?" "2"
out="$(ul status)"; assert_contains "drift suggests enforce" "$out" "enforce"
teardown

echo "== Task 9: enforce =="
setup
ul lock >/dev/null 2>&1
sum1="$(cksum < "$UL_STATE_DIR/state.tsv")"
rm -f "$UL_APT_CONF_DIR/99-update-lockdown"
: > "$UL_FAKE_SNAP_HOLD"
: > "$UL_FAKE_LOG"
ul enforce >/dev/null 2>&1; assert_eq "enforce exits 0" "$?" "0"
assert_eq "enforce never rewrites the state file" "$(cksum < "$UL_STATE_DIR/state.tsv")" "$sum1"
calls="$(cat "$UL_FAKE_LOG")"
assert_contains "enforce re-masks units"   "$calls" "systemctl mask apt-daily.timer"
assert_contains "enforce re-holds snap"    "$calls" "snap set system refresh.hold=forever"
assert_eq "enforce rewrites the dropin" "$(exists "$UL_APT_CONF_DIR/99-update-lockdown")" "yes"
teardown

echo "== Task 9b: enforce without a lock is a no-op =="
setup
ul enforce >/dev/null 2>&1; assert_eq "enforce exits 0 when unlocked" "$?" "0"
calls="$(cat "$UL_FAKE_LOG")"
assert_absent "enforce masks nothing when unlocked" "$calls" "systemctl mask"
assert_absent "enforce holds nothing when unlocked" "$calls" "snap set"
assert_eq "enforce creates no state file" "$(exists "$UL_STATE_DIR/state.tsv")" "no"
teardown

echo "== Task 9c: enforce leaves an intact lockdown alone =="
setup
ul lock >/dev/null 2>&1
sed -i "s/${T}enabled${T}/${T}masked${T}/; s/${T}static${T}/${T}masked${T}/" "$UL_FAKE_STATE"
: > "$UL_FAKE_LOG"
ul enforce >/dev/null 2>&1
assert_absent "already-masked units are skipped" "$(cat "$UL_FAKE_LOG")" "systemctl mask apt-daily.timer"
ul status >/dev/null 2>&1; assert_eq "still clean after enforce" "$?" "0"
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
