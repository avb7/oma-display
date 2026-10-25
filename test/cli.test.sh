#!/bin/bash
# bash test/cli.test.sh
#
# Runs bin/oma-display apply/clear against a scratch monitors.lua. hyprctl and
# Omarchy's helpers are stubbed, so nothing touches the real Hyprland session.

set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
cli="$here/bin/oma-display"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/home"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/hyprctl"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/omarchy-hyprland-monitor-internal"
chmod +x "$tmp/bin/"*

export PATH="$tmp/bin:$PATH"
export HOME="$tmp/home"
export XDG_STATE_HOME="$tmp/state"
export OMA_DISPLAY_MONITOR_LUA="$tmp/monitors.lua"

NEW_BEGIN="-- >>> oma-display (managed by the avb7.oma-display plugin; edits here are overwritten) >>>"
OLD_BEGIN="-- >>> display-arrange (managed by the avb7.display-arrange plugin; edits here are overwritten) >>>"
OLD_END="-- <<< display-arrange <<<"
PAYLOAD='[{"output":"eDP-1","mode":"1920x1200@60.00","x":0,"y":0,"scale":1,"transform":0}]'

passed=0
failed=0
ok() { echo "ok - $1"; passed=$((passed + 1)); }
not_ok() { echo "not ok - $1"; failed=$((failed + 1)); }
check() { if eval "$2"; then ok "$1"; else not_ok "$1"; fi; }
count() { grep -cF -- "$1" "$OMA_DISPLAY_MONITOR_LUA"; }

user_config() {
  cat <<EOF
-- my own monitor rules
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
EOF
}

legacy_block() {
  cat <<EOF

$OLD_BEGIN
hl.monitor({ output = "desc:JHW Z34B 0000000000001", mode = "3440x1440@75.00", position = "0x0", scale = 1, transform = 0 })
$OLD_END
EOF
}

# apply replaces the legacy block
{ user_config; legacy_block; } >"$OMA_DISPLAY_MONITOR_LUA"
"$cli" apply "$PAYLOAD" >/dev/null
check "apply removes the legacy block" '[[ $(count "display-arrange") == 0 ]]'
check "apply writes one new block" '[[ $(count "$NEW_BEGIN") == 1 ]]'
check "apply keeps the user rules" '[[ $(count "my own monitor rules") == 1 && $(count "output = \"\"") == 1 ]]'

# legacy and current blocks together collapse into one
{ user_config; legacy_block; printf '\n%s\n%s\n' "$NEW_BEGIN" "-- <<< oma-display <<<"; } >"$OMA_DISPLAY_MONITOR_LUA"
"$cli" apply "$PAYLOAD" >/dev/null
check "both blocks become one new block" '[[ $(count "display-arrange") == 0 && $(count "$NEW_BEGIN") == 1 ]]'

# repeated applies don't grow the file
"$cli" apply "$PAYLOAD" >/dev/null
size1=$(wc -l <"$OMA_DISPLAY_MONITOR_LUA")
"$cli" apply "$PAYLOAD" >/dev/null
size2=$(wc -l <"$OMA_DISPLAY_MONITOR_LUA")
check "repeated applies keep the same length" '[[ $size1 == "$size2" ]]'

# clear removes the legacy block
{ user_config; legacy_block; } >"$OMA_DISPLAY_MONITOR_LUA"
"$cli" clear >/dev/null
check "clear removes the legacy block" '[[ $(count "display-arrange") == 0 && $(count "oma-display") == 0 ]]'
check "clear keeps the user rules" '[[ $(count "my own monitor rules") == 1 ]]'

# a start marker with no end is refused, and the file is left alone
{ user_config; printf '\n%s\nhl.monitor({ output = "eDP-1" })\n' "$OLD_BEGIN"; user_config; } >"$OMA_DISPLAY_MONITOR_LUA"
before=$(cat "$OMA_DISPLAY_MONITOR_LUA")
"$cli" apply "$PAYLOAD" >/dev/null 2>&1
rc=$?
check "an unterminated block is refused" '[[ $rc != 0 ]]'
check "and the file is unchanged" '[[ "$(cat "$OMA_DISPLAY_MONITOR_LUA")" == "$before" ]]'
"$cli" clear >/dev/null 2>&1
rc=$?
check "clear refuses it too" '[[ $rc != 0 && "$(cat "$OMA_DISPLAY_MONITOR_LUA")" == "$before" ]]'

echo
echo "$passed passed, $failed failed"
[[ $failed == 0 ]]
