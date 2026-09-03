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

# Read authorized SteamID from config file
get_authorized_steamid() {
    local cfg="$1"
    [ -f "$cfg" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r '.authorized_steamid // empty' "$cfg" 2>/dev/null
    else
        sed -n 's/.*"authorized_steamid"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' "$cfg" 2>/dev/null | head -n1
    fi
}

# Read active SteamID from loginusers.vdf (the account with MostRecent == 1)
get_active_steamid() {
    local vdf="$1"
    [ -f "$vdf" ] || return 1
    awk '
        /^[[:space:]]*"[0-9]+"/ {
            current_id = $1
            gsub(/"/, "", current_id)
        }
        /"MostRecent"[[:space:]]+"1"/ {
            active_id = current_id
        }
        END {
            if (active_id != "") print active_id
        }
    ' "$vdf" 2>/dev/null
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
            id = $1; gsub(/"/, "", id)
            acc = ""; persona = ""; recent = "0"
        }
        /"AccountName"/ {
            acc = $0
            sub(/^[[:space:]]*"AccountName"[[:space:]]+"/, "", acc)
            sub(/"[[:space:]]*$/, "", acc)
        }
        /"PersonaName"/ {
            persona = $0
            sub(/^[[:space:]]*"PersonaName"[[:space:]]+"/, "", persona)
            sub(/"[[:space:]]*$/, "", persona)
        }
        /"MostRecent"/ {
            recent = $0
            sub(/^[[:space:]]*"MostRecent"[[:space:]]+"/, "", recent)
            sub(/"[[:space:]]*$/, "", recent)
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

    # Determine execution mode:
    # Fail-Secure policy: If no authorized_id is configured, or active_id cannot be verified,
    # or active_id does not match authorized_id -> RUN CLEAN.
    if [ -n "$authorized_id" ] && [ -n "$active_id" ] && [ "$active_id" = "$authorized_id" ]; then
        # ── AUTHORIZED MODDED USER ───────────────────────────────────────────
        manage_stplugin "restore" "$steam_root"
        if [ -x "$MODDED_WRAPPER" ]; then
            exec "$MODDED_WRAPPER" "$@"
        else
            # Modded wrapper missing; fallback to genuine Steam with warning
            manage_stplugin "hide" "$steam_root"
            sanitize_env_for_clean
            exec "$real_steam" "$@"
        fi
    else
        # ── CLEAN USER / UNAUTHORIZED / FAIL-SECURE ──────────────────────────
        manage_stplugin "hide" "$steam_root"
        sanitize_env_for_clean
        exec "$real_steam" "$@"
    fi
}

# When sourced (for testing), do not run main automatically
if [ "${GATEKEEPER_LIB_ONLY:-0}" = 0 ]; then
    main "$@"
fi
