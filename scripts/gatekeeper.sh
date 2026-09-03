#!/usr/bin/env bash
# ============================================================================
#  luatools-moon-secure — Gatekeeper Launcher
# ============================================================================
#  Acts as a security barrier in front of Steam (Game Mode and Desktop Mode).
#  Detects the currently active Steam account from loginusers.vdf:
#    - If it matches the authorized account -> runs with SLSsteam + Lumen + CloudRedirect.
#    - If it is a clean / unauthorized account -> runs 100% clean official Steam:
#        * No LD_AUDIT / SLSsteam.so
#        * No LD_PRELOAD / cloud_redirect.so
#        * No Lumen sidecar process
#        * stplug-in/ is hidden (stplug-in.modded) so unowned games do not appear
#        * Native Valve Steam Cloud works untouched and unintercepted
# ============================================================================

set -u

# Configurable paths (overrideable for testing)
GATEKEEPER_CONFIG="${GATEKEEPER_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/luatools-secure/config.json}"
MODDED_WRAPPER="${GATEKEEPER_MODDED_WRAPPER:-$HOME/.local/share/SLSsteam/path/steam.modded}"

# Find Steam root directory
find_steam_root() {
    if [ -n "${GATEKEEPER_STEAM_ROOT:-}" ] && [ -d "$GATEKEEPER_STEAM_ROOT" ]; then
        printf '%s' "$GATEKEEPER_STEAM_ROOT"
        return 0
    fi
    local candidates=(
        "$HOME/.steam/steam"
        "$HOME/.local/share/Steam"
        "$HOME/.steam/root"
        "$HOME/.steam/debian-installation"
    )
    for c in "${candidates[@]}"; do
        if [ -f "$c/config/loginusers.vdf" ]; then
            printf '%s' "$c"
            return 0
        fi
    done
    local deep
    deep="$(find "$HOME/.steam" "$HOME/.local/share/Steam" -maxdepth 3 -name "loginusers.vdf" -type f 2>/dev/null | head -n1)"
    if [ -n "$deep" ] && [ -f "$deep" ]; then
        dirname "$(dirname "$deep")"
        return 0
    fi
    for c in "${candidates[@]}"; do
        if [ -d "$c/config" ]; then
            printf '%s' "$c"
            return 0
        fi
    done
    if [ -d "$HOME/.steam/steam" ]; then
        printf '%s' "$HOME/.steam/steam"
        return 0
    fi
    printf '%s' "$HOME/.local/share/Steam"
}

# Resolve genuine system Steam binary (skipping our wrapper dirs)
find_real_steam() {
    if [ -n "${GATEKEEPER_REAL_STEAM:-}" ] && [ -x "$GATEKEEPER_REAL_STEAM" ]; then
        printf '%s' "$GATEKEEPER_REAL_STEAM"
        return 0
    fi

    local IFS=':'
    local dir candidate
    for dir in $PATH; do
        case "$dir" in
            *"/.local/share/SLSsteam-secure/bin"*|*"/.local/share/SLSsteam/path"*)
                continue
                ;;
        esac
        candidate="$dir/steam"
        if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    # Fallback to standard system paths
    for candidate in /usr/bin/steam /usr/games/steam /usr/local/bin/steam; do
        if [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    # Ultimate fallback
    printf '%s' "steam"
}

log_gatekeeper() {
    local log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/slsteam-moon"
    mkdir -p "$log_dir" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%F %T' 2>/dev/null || date)" "$1" >> "$log_dir/gatekeeper.log" 2>/dev/null || true
}

# Read authorized SteamID from config file
get_authorized_steamid() {
    local cfg="$1"
    [ -f "$cfg" ] || return 1
    local res=""
    if command -v jq >/dev/null 2>&1; then
        res="$(jq -r '.authorized_steamid // empty' "$cfg" 2>/dev/null)"
    else
        res="$(sed -n 's/.*"authorized_steamid"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' "$cfg" 2>/dev/null | head -n1)"
    fi
    res="$(printf '%s' "$res" | tr -d '\r[:space:]')"
    [ -n "$res" ] || return 1
    printf '%s' "$res"
}

# Read active SteamID from loginusers.vdf (the account with MostRecent == 1, or latest Timestamp)
get_active_steamid() {
    local vdf="$1"
    [ -f "$vdf" ] || return 1
    local res
    res="$(awk '
        /^[[:space:]]*"[0-9]+"/ {
            current_id = $1
            gsub(/[\r"]/, "", current_id)
            count++
            if (first_id == "") first_id = current_id
        }
        tolower($0) ~ /"mostrecent"[[:space:]]+"?1"?/ {
            active_id = current_id
        }
        tolower($0) ~ /"timestamp"/ {
            ts = $0
            sub(/^[[:space:]]*"[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp]"[[:space:]]+"?[^0-9]*/, "", ts)
            sub(/[^0-9].*$/, "", ts)
            if (ts + 0 > max_ts) {
                max_ts = ts + 0
                latest_id = current_id
            }
        }
        END {
            if (active_id != "") {
                print active_id
            } else if (latest_id != "") {
                print latest_id
            } else if (count == 1) {
                print first_id
            }
        }
    ' "$vdf" 2>/dev/null | tr -d '\r[:space:]')"
    [ -n "$res" ] || return 1
    printf '%s' "$res"
}

# List all Steam accounts found in loginusers.vdf
# Output format per line: SteamID|AccountName|PersonaName|MostRecent
list_steam_accounts() {
    local vdf="$1"
    [ -f "$vdf" ] || return 1
    awk '
        /^[[:space:]]*"[0-9]+"/ {
            if (id != "") {
                print id "|" acc "|" persona "|" recent
            }
            id = $1; gsub(/[\r"]/, "", id)
            acc = ""; persona = ""; recent = "0"
        }
        tolower($0) ~ /"accountname"/ {
            acc = $0
            sub(/^[[:space:]]*"[Aa][Cc][Cc][Oo][Uu][Nn][Tt][Nn][Aa][Mm][Ee]"[[:space:]]+"/, "", acc)
            sub(/"[\r[:space:]]*$/, "", acc)
        }
        tolower($0) ~ /"personaname"/ {
            persona = $0
            sub(/^[[:space:]]*"[Pp][Ee][Rr][Ss][Oo][Nn][Aa][Nn][Aa][Mm][Ee]"[[:space:]]+"/, "", persona)
            sub(/"[\r[:space:]]*$/, "", persona)
        }
        tolower($0) ~ /"mostrecent"[[:space:]]+"1"/ {
            recent = "1"
        }
        END {
            if (id != "") {
                print id "|" acc "|" persona "|" recent
            }
        }
    ' "$vdf" 2>/dev/null
}

# Isolate or restore stplug-in directory
# Mode: "hide" (for clean user) or "restore" (for modded user)
manage_stplugin() {
    local mode="$1"
    local steam_root="$2"
    local config_dir="$steam_root/config"
    local active_dir="$config_dir/stplug-in"
    local modded_dir="$config_dir/stplug-in.modded"

    mkdir -p "$config_dir" 2>/dev/null || true

    if [ "$mode" = "hide" ]; then
        if [ -d "$active_dir" ] && [ ! -L "$active_dir" ]; then
            # Move active stplug-in to modded backup so clean Steam does not load unowned games
            if [ -d "$modded_dir" ]; then
                # Merge or replace safely
                rm -rf "$modded_dir.bak" 2>/dev/null || true
                mv "$modded_dir" "$modded_dir.bak" 2>/dev/null || true
            fi
            mv "$active_dir" "$modded_dir" 2>/dev/null || true
        fi
    elif [ "$mode" = "restore" ]; then
        if [ -d "$modded_dir" ] && [ ! -d "$active_dir" ]; then
            mv "$modded_dir" "$active_dir" 2>/dev/null || true
        elif [ ! -d "$active_dir" ]; then
            mkdir -p "$active_dir" 2>/dev/null || true
        fi
    fi
}

# Clean injection variables for unmodded execution
sanitize_env_for_clean() {
    unset LD_AUDIT
    # Strip cloud_redirect.so if present in LD_PRELOAD
    if [ -n "${LD_PRELOAD:-}" ]; then
        local new_preload=""
        local IFS=': '
        for item in $LD_PRELOAD; do
            case "$item" in
                *cloud_redirect.so*) ;;
                *) new_preload="${new_preload:+$new_preload:}$item" ;;
            esac
        done
        if [ -n "$new_preload" ]; then
            export LD_PRELOAD="$new_preload"
        else
            unset LD_PRELOAD
        fi
    fi
}

main() {
    local steam_root
    steam_root="$(find_steam_root)"
    local vdf="$steam_root/config/loginusers.vdf"
    local authorized_id
    authorized_id="$(get_authorized_steamid "$GATEKEEPER_CONFIG" || true)"

    local active_id=""
    if [ -f "$vdf" ]; then
        active_id="$(get_active_steamid "$vdf" || true)"
    fi

    local real_steam
    real_steam="$(find_real_steam)"

    log_gatekeeper "INSPECT: root=${steam_root} vdf=${vdf} (exists: $([ -f "$vdf" ] && echo yes || echo no))"

    # Determine execution mode:
    # Fail-Secure policy: If no authorized_id is configured, or active_id cannot be verified,
    # or active_id does not match authorized_id -> RUN CLEAN.
    if [ -n "$authorized_id" ] && [ -n "$active_id" ] && [ "$active_id" = "$authorized_id" ]; then
        # ── AUTHORIZED MODDED USER ───────────────────────────────────────────
        log_gatekeeper "AUTHORIZED: active_id=${active_id} matches authorized_id=${authorized_id} -> starting modded Steam"
        manage_stplugin "restore" "$steam_root"
        if [ -x "$MODDED_WRAPPER" ] || [ -f "$MODDED_WRAPPER" ]; then
            export SLSM_STEAM_BIN="$real_steam"
            exec "$MODDED_WRAPPER" "$@"
        else
            log_gatekeeper "WARN: Modded wrapper missing at ${MODDED_WRAPPER} -> starting real steam"
            manage_stplugin "hide" "$steam_root"
            sanitize_env_for_clean
            exec "$real_steam" "$@"
        fi
    else
        # ── CLEAN USER / UNAUTHORIZED / FAIL-SECURE ──────────────────────────
        log_gatekeeper "CLEAN: active_id=${active_id:-empty} != authorized_id=${authorized_id:-none} -> starting clean official Steam"
        manage_stplugin "hide" "$steam_root"
        sanitize_env_for_clean
        exec "$real_steam" "$@"
    fi
}

# When sourced (for testing), do not run main automatically
if [ "${GATEKEEPER_LIB_ONLY:-0}" = 0 ]; then
    main "$@"
fi
