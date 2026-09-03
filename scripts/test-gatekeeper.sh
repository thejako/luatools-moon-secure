#!/usr/bin/env bash
# ============================================================================
# Unit tests for scripts/gatekeeper.sh
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEKEEPER_SH="$SCRIPT_DIR/gatekeeper.sh"

failures=0
check() { # $1 desc  $2 result(0/1)
    if [ "$2" -eq 0 ]; then printf 'ok:   %s\n' "$1"
    else printf 'FAIL: %s\n' "$1"; failures=$((failures+1)); fi
}

TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

export GATEKEEPER_LIB_ONLY=1
# shellcheck disable=SC1090
source "$GATEKEEPER_SH"

# ----------------------------------------------------------------------------
# Test 1: get_authorized_steamid
# ----------------------------------------------------------------------------
CFG="$TESTDIR/config.json"
cat > "$CFG" << 'EOF'
{
  "authorized_steamid": "76561198012345678",
  "authorized_account_name": "modded_user"
}
EOF

auth_id="$(get_authorized_steamid "$CFG")"
[ "$auth_id" = "76561198012345678" ]; check "get_authorized_steamid: reads valid json" $?

no_auth="$(get_authorized_steamid "$TESTDIR/nonexistent.json" || true)"
[ -z "$no_auth" ]; check "get_authorized_steamid: nonexistent file -> empty" $?

# ----------------------------------------------------------------------------
# Test 2: get_active_steamid from loginusers.vdf
# ----------------------------------------------------------------------------
VDF="$TESTDIR/loginusers.vdf"
cat > "$VDF" << 'EOF'
"users"
{
	"76561198011111111"
	{
		"AccountName"		"clean_account"
		"PersonaName"		"CleanUser"
		"RememberPassword"		"1"
		"MostRecent"		"0"
		"Timestamp"		"1700000000"
	}
	"76561198022222222"
	{
		"AccountName"		"modded_account"
		"PersonaName"		"ModdedUser"
		"RememberPassword"		"1"
		"MostRecent"		"1"
		"Timestamp"		"1700001000"
	}
}
EOF

active_id="$(get_active_steamid "$VDF")"
[ "$active_id" = "76561198022222222" ]; check "get_active_steamid: detects MostRecent account" $?

# Swap MostRecent: clean user becomes active
cat > "$VDF" << 'EOF'
"users"
{
	"76561198011111111"
	{
		"AccountName"		"clean_account"
		"PersonaName"		"CleanUser"
		"RememberPassword"		"1"
		"MostRecent"		"1"
		"Timestamp"		"1700002000"
	}
	"76561198022222222"
	{
		"AccountName"		"modded_account"
		"PersonaName"		"ModdedUser"
		"RememberPassword"		"1"
		"MostRecent"		"0"
		"Timestamp"		"1700001000"
	}
}
EOF

active_id2="$(get_active_steamid "$VDF")"
[ "$active_id2" = "76561198011111111" ]; check "get_active_steamid: correctly switches to clean account" $?

# Test list_steam_accounts
accounts_list="$(list_steam_accounts "$VDF")"
echo "$accounts_list" | grep -q "76561198011111111|clean_account|CleanUser|1"
check "list_steam_accounts: lists account 1 with persona and most recent flag" $?
echo "$accounts_list" | grep -q "76561198022222222|modded_account|ModdedUser|0"
check "list_steam_accounts: lists account 2" $?

# ----------------------------------------------------------------------------
# Test 3: manage_stplugin (hide and restore)
# ----------------------------------------------------------------------------
FAKE_STEAM="$TESTDIR/steam_root"
mkdir -p "$FAKE_STEAM/config/stplug-in"
echo "test game" > "$FAKE_STEAM/config/stplug-in/12345.lua"

# Hide stplug-in for clean user
manage_stplugin "hide" "$FAKE_STEAM"
[ ! -d "$FAKE_STEAM/config/stplug-in" ] && [ -d "$FAKE_STEAM/config/stplug-in.modded" ] && [ -f "$FAKE_STEAM/config/stplug-in.modded/12345.lua" ]
check "manage_stplugin hide: renames stplug-in to stplug-in.modded" $?

# Restore stplug-in for modded user
manage_stplugin "restore" "$FAKE_STEAM"
[ -d "$FAKE_STEAM/config/stplug-in" ] && [ ! -d "$FAKE_STEAM/config/stplug-in.modded" ] && [ -f "$FAKE_STEAM/config/stplug-in/12345.lua" ]
check "manage_stplugin restore: renames stplug-in.modded back to stplug-in" $?

# ----------------------------------------------------------------------------
# Test 4: sanitize_env_for_clean
# ----------------------------------------------------------------------------
export LD_AUDIT="/some/path/SLSsteam.so"
export LD_PRELOAD="/usr/lib/libother.so:/home/deck/.local/share/CloudRedirect/cloud_redirect.so"
sanitize_env_for_clean
[ -z "${LD_AUDIT:-}" ]; check "sanitize_env: unsets LD_AUDIT" $?
[ "${LD_PRELOAD:-}" = "/usr/lib/libother.so" ]; check "sanitize_env: strips cloud_redirect.so from LD_PRELOAD" $?

export LD_PRELOAD="/home/deck/.local/share/CloudRedirect/cloud_redirect.so"
sanitize_env_for_clean
[ -z "${LD_PRELOAD:-}" ]; check "sanitize_env: fully unsets LD_PRELOAD if only cloud_redirect was present" $?

# ----------------------------------------------------------------------------
# Test 5: End-to-End simulation of gatekeeper.sh
# ----------------------------------------------------------------------------
FAKE_BIN="$TESTDIR/bin"
mkdir -p "$FAKE_BIN"
MOCK_LOG="$TESTDIR/mock.log"

REAL_STEAM_MOCK="$FAKE_BIN/real_steam"
cat > "$REAL_STEAM_MOCK" << 'EOF'
#!/usr/bin/env bash
echo "LAUNCHED_REAL_STEAM" > "$MOCK_LOG"
EOF
chmod +x "$REAL_STEAM_MOCK"

MODDED_WRAPPER_MOCK="$FAKE_BIN/modded_steam"
cat > "$MODDED_WRAPPER_MOCK" << 'EOF'
#!/usr/bin/env bash
echo "LAUNCHED_MODDED_STEAM" > "$MOCK_LOG"
EOF
chmod +x "$MODDED_WRAPPER_MOCK"

# Case A: Active user is authorized modded account -> launches modded steam
cat > "$CFG" << 'EOF'
{ "authorized_steamid": "76561198022222222" }
EOF
mkdir -p "$FAKE_STEAM/config"
VDF="$FAKE_STEAM/config/loginusers.vdf"
cat > "$VDF" << 'EOF'
"users"
{
	"76561198022222222"
	{
		"MostRecent"		"1"
	}
}
EOF
rm -f "$MOCK_LOG"
export MOCK_LOG
GATEKEEPER_CONFIG_FILE="$CFG" \
GATEKEEPER_STEAM_ROOT="$FAKE_STEAM" \
GATEKEEPER_REAL_STEAM="$REAL_STEAM_MOCK" \
GATEKEEPER_MODDED_WRAPPER="$MODDED_WRAPPER_MOCK" \
GATEKEEPER_LIB_ONLY=0 \
bash "$GATEKEEPER_SH"

[ "$(cat "$MOCK_LOG" 2>/dev/null)" = "LAUNCHED_MODDED_STEAM" ]; check "e2e: authorized user triggers modded steam wrapper" $?
[ -d "$FAKE_STEAM/config/stplug-in" ]; check "e2e: authorized user ensures stplug-in is active" $?

# Case B: Active user is clean account -> launches real steam and hides stplug-in
cat > "$VDF" << 'EOF'
"users" {
	"76561198011111111" {
		"MostRecent" "1"
	}
}
EOF
rm -f "$MOCK_LOG"
GATEKEEPER_CONFIG_FILE="$CFG" \
GATEKEEPER_STEAM_ROOT="$FAKE_STEAM" \
GATEKEEPER_REAL_STEAM="$REAL_STEAM_MOCK" \
GATEKEEPER_MODDED_WRAPPER="$MODDED_WRAPPER_MOCK" \
GATEKEEPER_LIB_ONLY=0 \
bash "$GATEKEEPER_SH"

[ "$(cat "$MOCK_LOG" 2>/dev/null)" = "LAUNCHED_REAL_STEAM" ]; check "e2e: clean user triggers real steam" $?
[ ! -d "$FAKE_STEAM/config/stplug-in" ] && [ -d "$FAKE_STEAM/config/stplug-in.modded" ]
check "e2e: clean user hides stplug-in directory" $?

# Case C: No loginusers.vdf (Fail-Secure) -> launches real steam
rm -f "$VDF" "$MOCK_LOG"
GATEKEEPER_CONFIG_FILE="$CFG" \
GATEKEEPER_STEAM_ROOT="$FAKE_STEAM" \
GATEKEEPER_REAL_STEAM="$REAL_STEAM_MOCK" \
GATEKEEPER_MODDED_WRAPPER="$MODDED_WRAPPER_MOCK" \
GATEKEEPER_LIB_ONLY=0 \
bash "$GATEKEEPER_SH"

[ "$(cat "$MOCK_LOG" 2>/dev/null)" = "LAUNCHED_REAL_STEAM" ]; check "e2e: missing vdf fails secure to real steam" $?

if [ "$failures" -eq 0 ]; then
    echo
    echo "ALL PASS"
    exit 0
fi
echo
echo "$failures CHECK(S) FAILED"
exit 1
EOF
