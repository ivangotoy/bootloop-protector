#!/bin/sh
# Off-device tests for Bootloop Protector.
#   sh tests/run.sh
# Syntax checks of every script, then the real module scripts run against a
# fake /data/adb (BP_ROOT, see common.sh) with stub Android commands.
# BP_TEST_SH picks the shell that runs the module scripts (default: sh).
# tests/module-ci-release.sh runs .forgejo/module-ci.sh release against a fake forge.
# tests/ is not part of the module zip (.forgejo/module-ci.conf lists what is packed).

REPO=$(cd "$(dirname "$0")/.." && pwd)
SH=${BP_TEST_SH:-sh}
PASS=0
FAIL=0
SKIP=0

# The module reboots through this path: never run where it exists
[ -e /system/bin/reboot ] && { echo "refusing to run: /system/bin/reboot exists"; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "timeout command is needed"; exit 1; }

W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
trap 'exit 1' INT TERM

ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
skip() { SKIP=$((SKIP + 1)); echo "skip $1"; }
check() { _n=$1; shift; if "$@"; then ok "$_n"; else bad "$_n"; fi; }
has() { grep -Fq -e "$2" "$1" 2>/dev/null; }
hasx() { grep -Fxq -e "$2" "$1" 2>/dev/null; }
not() { if "$@"; then return 1; else return 0; fi; }

# ---------- declared checks ----------

for f in "$REPO"/*.sh "$REPO"/META-INF/com/google/android/update-binary; do
  check "syntax ${f#"$REPO"/}" $SH -n "$f"
done
if command -v bash >/dev/null 2>&1; then
  check "syntax .forgejo/module-ci.sh" bash -n "$REPO/.forgejo/module-ci.sh"
else
  skip "syntax .forgejo/module-ci.sh (no bash)"
fi
if command -v python3 >/dev/null 2>&1; then
  for j in update.json .forgejo/update.json; do
    check "json $j" python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$REPO/$j"
  done
  if python3 -I -c 'import yaml' 2>/dev/null; then
    check "yaml .forgejo/workflows/module-release.yml" \
      python3 -I -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$REPO/.forgejo/workflows/module-release.yml"
  else
    skip "yaml .forgejo/workflows/module-release.yml (no python3 yaml)"
  fi
else
  skip "json and yaml checks (no python3)"
fi

# ---------- stub Android commands ----------

mkdir -p "$W/bin"
REAL_DATE=$(command -v date)
cat > "$W/bin/date" <<EOF
#!/bin/sh
# date +%s is a clock that moves STUB_TICK seconds per call
if [ "\$1" = +%s ]; then
  t=\$(( \$(cat "\$STUB_R/clock") + \${STUB_TICK:-1} ))
  echo "\$t" > "\$STUB_R/clock"
  echo "\$t"
  exit 0
fi
exec "$REAL_DATE" "\$@"
EOF
cat > "$W/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  sys.boot_completed) cat "$STUB_R/boot_completed" 2>/dev/null ;;
  sys.shutdown.requested)
    # answers "shutting down" after STUB_SHUTDOWN_AFTER questions, which ends service.sh
    n=$(( $(cat "$STUB_R/shutdown.n" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$STUB_R/shutdown.n"
    [ "$n" -gt "${STUB_SHUTDOWN_AFTER:-0}" ] && echo 1
    ;;
esac
exit 0
EOF
cat > "$W/bin/setprop" <<'EOF'
#!/bin/sh
echo "setprop $*" >> "$STUB_R/calls"
EOF
# no process ever matches unless a test adds $R/pidof, whose pids are above
# any pid_max: nothing real can be signalled
printf '#!/bin/sh\n[ -x "$STUB_R/pidof" ] && exec "$STUB_R/pidof" "$@"\nexit 1\n' > "$W/bin/pidof"
printf '#!/bin/sh\nexit 1\n' > "$W/bin/pgrep"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/sleep"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/sync"
chmod 755 "$W/bin"/*

# ---------- fake device ----------

# setup NAME - fresh /data/adb with this module, its data folder and defaults
setup() {
  R="$W/$1"
  ADB="$R/data/adb"
  MOD="$ADB/modules/bootloop-protector"
  DATA="$ADB/bootloop-protector"
  mkdir -p "$MOD" "$DATA/state" "$ADB/service.d"
  cp "$REPO/module.prop" "$MOD/module.prop"
  cp "$REPO/defaults/config" "$REPO/defaults/allowed-modules.txt" "$REPO/defaults/allowed-scripts.txt" "$DATA/"
  conf VOLKEY_RESCUE 0
  conf SYSTEMUI_MONITOR 0
  echo 1700000000 > "$R/clock"
  : > "$R/calls"
}

conf() { sed -i "s/^$1=.*/$1=$2/" "$DATA/config"; }
state() { cat "$DATA/state/$1" 2>/dev/null; }

# add_mod ID [VERSION] - an enabled module with a boot script
add_mod() {
  mkdir -p "$ADB/modules/$1"
  printf 'id=%s\nname=Example %s\nversion=%s\nversionCode=1\n' "$1" "$1" "${2:-v1}" > "$ADB/modules/$1/module.prop"
  printf '#!/system/bin/sh\n' > "$ADB/modules/$1/service.sh"
}

add_script() { printf '#!/system/bin/sh\n' > "$ADB/service.d/$1"; chmod 755 "$ADB/service.d/$1"; }

# run SCRIPT [ARGS] - the real script from the repo, output in $R/out
run() {
  _s=$1
  shift
  (cd "$R" && PATH="$W/bin:$PATH" BP_ROOT="$R" STUB_R="$R" timeout 120 $SH "$REPO/$_s" "$@") > "$R/out" 2>&1
}

rebooted() { has "$R/calls" "setprop sys.powerctl reboot"; }
disabled() { [ -f "$ADB/modules/$1/disable" ]; }
executable() { [ -x "$ADB/service.d/$1" ]; }

# ---------- post-fs-data.sh ----------

setup pfd-first
run post-fs-data.sh
check "post-fs-data: first boot counts attempt 1" [ "$(state attempts)" = 1 ]
check "post-fs-data: module card shows booting" has "$MOD/module.prop" "description=⏳ Booting... (attempt 1 of 3 allowed)"
check "post-fs-data: first boot does not reboot" not rebooted

setup pfd-level2
add_mod example_mod
add_mod example_keep
add_mod example_meta
ln -s ../modules/example_meta "$ADB/metamodule"
echo example_keep >> "$DATA/allowed-modules.txt"
add_script example.sh
add_script keep.sh
echo keep.sh >> "$DATA/allowed-scripts.txt"
echo 3 > "$DATA/state/attempts"
run post-fs-data.sh
check "boot loop without trusted setup: level 2" [ "$(state level)" = 2 ]
check "level 2: module disabled" disabled example_mod
check "level 2: never-disable module kept" not disabled example_keep
check "level 2: metamodule kept" not disabled example_meta
check "level 2: script disabled" not executable example.sh
check "level 2: never-disable script kept" executable keep.sh
check "level 2: rescue list records the module" hasx "$DATA/state/rescue.list" "module:example_mod"
check "level 2: rescue list records the script" hasx "$DATA/state/rescue.list" "script:$ADB/service.d/example.sh"
check "level 2: attempts reset" [ "$(state attempts)" = 0 ]
check "level 2: reboots" rebooted

setup pfd-dash-name
add_script -x.sh
printf '%s\n' -x.sh >> "$DATA/allowed-scripts.txt"
echo 3 > "$DATA/state/attempts"
run post-fs-data.sh
check "never-disable script named -x.sh kept by a rescue" executable -x.sh

setup pfd-level1
add_mod example_a
add_mod example_b
run bp.sh trust-now
check "trust-now: trusted setup recorded" [ -s "$DATA/state/baseline" ]
add_mod example_new
add_mod example_b v2
run bp.sh modules
check "modules: unchanged module is trusted" hasx "$R/out" "example_a	Example example_a	v1	trusted	0"
check "modules: updated module is changed" hasx "$R/out" "example_b	Example example_b	v2	changed	0"
check "modules: added module is new" hasx "$R/out" "example_new	Example example_new	v1	new	0"
echo 3 > "$DATA/state/attempts"
run post-fs-data.sh
check "boot loop with trusted setup: level 1" [ "$(state level)" = 1 ]
check "level 1: new module disabled" disabled example_new
check "level 1: updated module disabled" disabled example_b
check "level 1: unchanged module kept" not disabled example_a
check "level 1: reboots" rebooted
run bp.sh restore
check "restore: re-enables what the rescue disabled" hasx "$R/out" "Re-enabled 2 item(s). Reboot to apply."
check "restore: modules enabled again" not disabled example_new
check "restore: rescue list closed" [ ! -f "$DATA/state/rescue.list" ]

setup pfd-empty-baseline
run bp.sh trust-now
add_mod example_new
add_mod example_other
echo example_other >> "$DATA/allowed-modules.txt"
echo 3 > "$DATA/state/attempts"
run post-fs-data.sh
check "trusted empty setup: level 1 disables the new module" disabled example_new
check "trusted empty setup: level 1" [ "$(state level)" = 1 ]

setup pfd-gaveup
add_mod example_mod
touch "$ADB/modules/example_mod/disable"
echo 2 > "$DATA/state/level"
echo 3 > "$DATA/state/attempts"
run post-fs-data.sh
check "both levels used: gives up" [ -f "$DATA/state/gaveup" ]
check "both levels used: no reboot" not rebooted
check "gave up: module card says so" has "$MOD/module.prop" "description=❌ Gave up"

setup pfd-desc-tmp-fails
mkdir "$MOD/module.prop.tmp"
run post-fs-data.sh
check "module card temp copy not writable: module.prop kept" hasx "$MOD/module.prop" "id=bootloop-protector"

# ---------- service.sh ----------

setup svc-good
add_mod example_mod
conf TRUST_MINUTES 1
echo 1 > "$R/boot_completed"
echo 2 > "$DATA/state/attempts"
STUB_TICK=10 STUB_SHUTDOWN_AFTER=30 run service.sh
check "service: good boot resets attempts" [ "$(state attempts)" = 0 ]
check "service: good boot logged" has "$DATA/bp.log" "Good boot"
check "service: setup trusted after TRUST_MINUTES" has "$DATA/bp.log" "Setup trusted after 1 min without problems"
check "service: trusted setup holds the module" has "$DATA/state/baseline" "module:example_mod "
check "service: no reboot" not rebooted

setup svc-sysui-after-rescue
add_mod example_mod
touch "$ADB/modules/example_mod/disable"
echo module:example_mod > "$DATA/state/rescue.list"
printf 'time=1600000000\nlevel=1\nreason=example\ncount=1\n' > "$DATA/state/last-rescue"
conf SYSTEMUI_MONITOR 1
conf TRUST_MINUTES 1
echo 1 > "$R/boot_completed"
# SystemUI goes down in the same poll that skips trusting the setup
cat > "$R/pidof" <<'EOF'
#!/bin/sh
[ "$1" = com.android.systemui ] || exit 1
grep -q "Not trusting this setup" "$STUB_R/data/adb/bootloop-protector/bp.log" && exit 1
echo 99999999
EOF
chmod 755 "$R/pidof"
STUB_TICK=10 STUB_SHUTDOWN_AFTER=60 run service.sh
check "service: SystemUI down after the trust check gets its 30 s" has "$DATA/bp.log" "FAILURE: SystemUI not running for 30s"

setup svc-timeout
conf BOOT_TIMEOUT 60
STUB_TICK=10 STUB_SHUTDOWN_AFTER=100 run service.sh
check "service: stuck boot is rebooted" rebooted
check "service: stuck boot logged" has "$DATA/bp.log" "Boot did not complete in 60s"

setup svc-conf-zero
conf TRUST_MINUTES 08
echo 1 > "$R/boot_completed"
STUB_TICK=60 STUB_SHUTDOWN_AFTER=40 run service.sh
check "config 08: read as 8, service keeps running to the trust point" has "$DATA/bp.log" "Setup trusted after 8 min without problems"

setup svc-conf-long
conf BOOT_TIMEOUT 99999999999999999999
STUB_TICK=10 STUB_SHUTDOWN_AFTER=100 run service.sh
check "config with 20 digits: default boot timeout applies" has "$DATA/bp.log" "Boot did not complete in 180s"

# ---------- uninstall.sh ----------

setup uninstall-rescued
add_mod example_mod
add_mod example_off
touch "$ADB/modules/example_mod/disable" "$ADB/modules/example_off/disable"
add_script example.sh
chmod 644 "$ADB/service.d/example.sh"
printf 'module:example_mod\nscript:%s\n' "$ADB/service.d/example.sh" > "$DATA/state/rescue.list"
run uninstall.sh
check "uninstall: exits 0" [ $? = 0 ]
check "uninstall: module disabled by the rescue enabled again" not disabled example_mod
check "uninstall: script disabled by the rescue executable again" executable example.sh
check "uninstall: module disabled by hand stays disabled" disabled example_off
check "uninstall: data folder removed" [ ! -e "$DATA" ]
check "uninstall: no reboot" not rebooted

setup uninstall-no-list
add_mod example_off
touch "$ADB/modules/example_off/disable"
run uninstall.sh
check "uninstall without a rescue list: exits 0" [ $? = 0 ]
check "uninstall without a rescue list: nothing enabled" disabled example_off
check "uninstall without a rescue list: data folder removed" [ ! -e "$DATA" ]

setup uninstall-no-data
rm -rf "$DATA"
run uninstall.sh
check "uninstall without a data folder: exits 0" [ $? = 0 ]
check "uninstall without a data folder: none created" [ ! -e "$DATA" ]

setup uninstall-no-common
add_mod example_mod
touch "$ADB/modules/example_mod/disable"
echo module:example_mod > "$DATA/state/rescue.list"
mkdir "$R/lone"
cp "$REPO/uninstall.sh" "$R/lone/uninstall.sh"
(cd "$R" && PATH="$W/bin:$PATH" BP_ROOT="$R" timeout 60 $SH "$R/lone/uninstall.sh") > "$R/out" 2>&1
check "uninstall without common.sh: exits 0" [ $? = 0 ]
check "uninstall without common.sh: data folder removed" [ ! -e "$DATA" ]

# ---------- bp.sh ----------

setup cli
run bp.sh set-conf BOOT_TIMEOUT 240
check "set-conf: valid value saved" hasx "$DATA/config" "BOOT_TIMEOUT=240"
run bp.sh set-conf BOOT_TIMEOUT 5
check "set-conf: out of range refused" hasx "$R/out" "Out of range"
run bp.sh set-conf BOOT_TIMEOUT '1;x'
check "set-conf: non-number refused" hasx "$R/out" "Bad value"
run bp.sh set-conf PATH 1
check "set-conf: unknown key refused" hasx "$R/out" "Unknown setting"
check "set-conf: refused values change nothing" hasx "$DATA/config" "BOOT_TIMEOUT=240"
run bp.sh set-conf BOOT_TIMEOUT 0300
check "set-conf: leading zero refused" hasx "$R/out" "Bad value"
run bp.sh set-conf BOOT_TIMEOUT 99999999999999999999
check "set-conf: 20 digits refused" hasx "$R/out" "Out of range"
check "set-conf: refused numerals change nothing" hasx "$DATA/config" "BOOT_TIMEOUT=240"
conf TRUST_MINUTES 010
run bp.sh conf
check "conf: 010 is read as 10" hasx "$R/out" "TRUST_MINUTES=10"
run bp.sh allow-module '../example' 1
check "allow-module: path in id refused" hasx "$R/out" "Bad module id"
run bp.sh allow-script 'a/b.sh' 1
check "allow-script: path refused" hasx "$R/out" "Bad script name"
echo keep.sh >> "$DATA/allowed-scripts.txt"
run bp.sh allow-script -x.sh 1
check "allow-script: name starting with - added" hasx "$DATA/allowed-scripts.txt" "-x.sh"
run bp.sh allow-script -x.sh 0
check "allow-script: name starting with - removed" not hasx "$DATA/allowed-scripts.txt" "-x.sh"
check "allow-script: other entries kept" hasx "$DATA/allowed-scripts.txt" "keep.sh"
run bp.sh allow-script 'a#b.sh' 1
check "allow-script: name with # refused" hasx "$R/out" "Bad script name"
check "allow-script: refused name not written" not has "$DATA/allowed-scripts.txt" "a#b.sh"
run bp.sh allow-script ' a.sh' 1
check "allow-script: name with a leading space refused" hasx "$R/out" "Bad script name"
run bp.sh allow-module example_mod 1
check "allow-module: added" hasx "$DATA/allowed-modules.txt" "example_mod"
run bp.sh allow-module example_mod 0
check "allow-module: removed" not hasx "$DATA/allowed-modules.txt" "example_mod"
check "allow-module: comments kept" has "$DATA/allowed-modules.txt" "# Allowed modules"

setup cli-hand-edited
printf 'example_crlf\r\n  example_sp  \nexample_cmt # a note\nexample_keep\n' >> "$DATA/allowed-modules.txt"
run bp.sh allow-module example_crlf 1
check "allow-module: entry with CR not added twice" [ "$(grep -c example_crlf "$DATA/allowed-modules.txt")" = 1 ]
for id in example_crlf example_sp example_cmt; do
  run bp.sh allow-module "$id" 0
  check "allow-module: hand-edited $id removed" not has "$DATA/allowed-modules.txt" "$id"
done
check "allow-module: hand-edited list keeps other entries" hasx "$DATA/allowed-modules.txt" "example_keep"
run bp.sh allow-script -n 1
check "allow-script: name -n added" hasx "$DATA/allowed-scripts.txt" "-n"

setup cli-no-final-newline
printf 'example_keep' >> "$DATA/allowed-modules.txt"
run bp.sh allow-module example_mod 1
check "allow-module: list without final newline keeps its last entry" hasx "$DATA/allowed-modules.txt" "example_keep"
check "allow-module: list without final newline gets the new entry" hasx "$DATA/allowed-modules.txt" "example_mod"
grep -v '^VOLKEY_RESCUE=' "$DATA/config" | grep -v '^MAX_ATTEMPTS=' > "$R/config"
printf 'VOLKEY_RESCUE=0' >> "$R/config"
cp "$R/config" "$DATA/config"
run bp.sh set-conf MAX_ATTEMPTS 5
run bp.sh conf
check "set-conf: config without final newline gets the new setting" hasx "$R/out" "MAX_ATTEMPTS=5"
check "set-conf: config without final newline keeps its last setting" hasx "$DATA/config" "VOLKEY_RESCUE=0"

setup cli-list-tmp-fails
echo example_keep >> "$DATA/allowed-modules.txt"
mkdir "$DATA/allowed-modules.txt.tmp"
run bp.sh allow-module example_other 0
check "allow-module: temp copy not writable keeps the list" hasx "$DATA/allowed-modules.txt" "example_keep"
check "allow-module: temp copy not writable is reported" not hasx "$R/out" "ok"

setup cli-enable-all
add_mod example_a
add_mod example_b
touch "$ADB/modules/example_a/disable" "$ADB/modules/example_b/disable"
run bp.sh enable-all
check "enable-all: reports the modules it enabled" hasx "$R/out" "Enabled 2 module(s). Reboot to apply."
check "enable-all: modules enabled" not disabled example_a

# ---------- .forgejo/module-ci.sh release, offline ----------

if command -v bash >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 &&
   command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  bash "$REPO/tests/module-ci-release.sh" > "$W/mci.out" 2>&1
  mrc=$?
  while IFS= read -r l; do
    case "$l" in
      "ok   "*) ok "module-ci ${l#ok   }" ;;
      "FAIL "*) bad "module-ci ${l#FAIL }" ;;
      "     "*) echo "$l" ;;
    esac
  done < "$W/mci.out"
  if [ "$mrc" != 0 ]; then bad "module-ci release harness exited $mrc"; tail -n 5 "$W/mci.out"; fi
else
  skip "module-ci release harness (needs bash, python3, git and curl)"
fi

echo ""
echo "passed $PASS, failed $FAIL, skipped $SKIP (module scripts run with: $SH)"
[ "$FAIL" = 0 ]
