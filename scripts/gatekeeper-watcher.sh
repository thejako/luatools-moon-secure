#!/usr/bin/env bash
# ============================================================================
#  luatools-moon-secure — Gatekeeper Session Watcher
# ============================================================================
#  Monitors Steam user session transitions in real time:
#    - When an unauthorized (clean) user logs in:
#        * Hides config/stplug-in -> config/stplug-in.modded immediately.
#        * Terminates Lumen sidecar.
#        * Relaunches Steam cleanly (free of LD_AUDIT / LD_PRELOAD / CloudRedirect).
#    - When the authorized user logs back in:
#        * Restores config/stplug-in.modded -> config/stplug-in.
#        * Relaunches Steam with modded hooks (SLSsteam + CloudRedirect + Lumen).
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEKEEPER_SH="${SCRIPT_DIR}/gatekeeper.sh"

# Source shared Gatekeeper helpers if available
if [ -f "$GATEKEEPER_SH" ]; then
    GATEKEEPER_LIB_ONLY=1
    # shellcheck disable=SC1090
    . "$GATEKEEPER_SH"
fi

GATEKEEPER_CONFIG="${GATEKEEPER_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/luatools-secure/config.json}"
MODDED_WRAPPER="${GATEKEEPER_MODDED_WRAPPER:-$HOME/.local/share/SLSsteam/path/steam.modded}"
GATEKEEPER_WRAPPER="${GATEKEEPER_WRAPPER_BIN:-$HOME/.local/share/SLSsteam/path/steam}"
WATCHER_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/slsteam-moon"
WATCHER_PIDFILE="${WATCHER_STATE_DIR}/gatekeeper-watcher.pid"
WATCHER_LOGFILE="${WATCHER_STATE_DIR}/gatekeeper.log"

log_watcher() {
    mkdir -p "$WATCHER_STATE_DIR" 2>/dev/null || true
    printf '%s [WATCHER] %s\n' "$(date '+%F %T' 2>/dev/null || date)" "$1" >> "$WATCHER_LOGFILE" 2>/dev/null || true
}

# Fallback implementations in case gatekeeper.sh was not sourced
if ! declare -f find_steam_root >/dev/null 2>&1; then
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
    printf '%s' "$HOME/.local/share/Steam"
}
fi

if ! declare -f get_authorized_steamid >/dev/null 2>&1; then
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
fi

if ! declare -f get_active_steamid >/dev/null 2>&1; then
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
fi

if ! declare -f manage_stplugin >/dev/null 2>&1; then
manage_stplugin() {
    local mode="$1"
    local steam_root="$2"
    local config_dir="$steam_root/config"
    local active_dir="$config_dir/stplug-in"
    local modded_dir="$config_dir/stplug-in.modded"

    mkdir -p "$config_dir" 2>/dev/null || true

    if [ "$mode" = "hide" ]; then
        if [ -d "$active_dir" ] && [ ! -L "$active_dir" ]; then
            if [ -d "$modded_dir" ]; then
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
fi

if ! declare -f find_real_steam >/dev/null 2>&1; then
find_real_steam() {
    if [ -n "${GATEKEEPER_REAL_STEAM:-}" ] && [ -x "$GATEKEEPER_REAL_STEAM" ]; then
        printf '%s' "$GATEKEEPER_REAL_STEAM"
        return 0
    fi
    for candidate in /usr/bin/steam /usr/games/steam /usr/local/bin/steam; do
        if [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf '%s' "steam"
}
fi

# Detect whether Steam is running
is_steam_running() {
    if [ -n "${WATCHER_MOCK_STEAM_RUNNING:-}" ]; then
        [ "$WATCHER_MOCK_STEAM_RUNNING" = "1" ]
        return $?
    fi
    pgrep -x steam >/dev/null 2>&1 || \
    pgrep -f "/steam.sh" >/dev/null 2>&1 || \
    pgrep -f "ubuntu12_32/steam" >/dev/null 2>&1
}

# Determine current session configuration mode
get_current_session_mode() {
    local steam_root="$1"
    if [ -d "$steam_root/config/stplug-in" ]; then
        printf 'modded'
    elif [ -d "$steam_root/config/stplug-in.modded" ]; then
        printf 'clean'
    else
        printf 'clean'
    fi
}

# Graceful or forced restart of Steam
restart_steam() {
    local target_mode="$1" # "clean" or "modded"
    local steam_root="$2"
    local real_steam="$3"
    local wrapper="$GATEKEEPER_WRAPPER"

    log_watcher "ACTION: Restarting Steam to switch mode -> ${target_mode}"

    # When switching to clean: immediately stop Lumen sidecar so CDP injection ceases
    if [ "$target_mode" = "clean" ]; then
        pkill -f "$HOME/.local/share/Lumen/lumen" 2>/dev/null || true
    fi

    if [ "${WATCHER_SKIP_RESTART_EXEC:-0}" = 1 ]; then
        log_watcher "ACTION (dry-run/test): Skipped actual process kill and restart"
        return 0
    fi

    local in_gamemode=0
    if [ "${XDG_CURRENT_DESKTOP:-}" = "gamescope" ] || [ -n "${STEAMOS_GAMEMODE:-}" ] || pgrep -x gamescope >/dev/null 2>&1; then
        in_gamemode=1
    fi

    # 1. Request graceful shutdown
    if [ -x "$real_steam" ]; then
        "$real_steam" -shutdown >/dev/null 2>&1 || true
    fi

    # Wait up to 6 seconds for Steam to exit cleanly
    local waited=0
    while is_steam_running && [ "$waited" -lt 6 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    # 2. Escalate to SIGTERM if still running
    if is_steam_running; then
        log_watcher "WARN: Steam did not exit within timeout, sending SIGTERM"
        pkill -TERM -x steam 2>/dev/null || true
        sleep 2
    fi

    # 3. Escalate to SIGKILL if still alive
    if is_steam_running; then
        log_watcher "WARN: Steam still running after SIGTERM, sending SIGKILL"
        pkill -KILL -x steam 2>/dev/null || true
        sleep 1
    fi

    # In Game Mode, SteamOS automatically relaunches Steam via PATH
    if [ "$in_gamemode" -eq 1 ]; then
        log_watcher "Game Mode active: SteamOS session supervisor will relaunch Steam automatically via Gatekeeper"
        return 0
    fi

    # In Desktop Mode, launch Steam explicitly through Gatekeeper
    log_watcher "Desktop Mode active: relaunching Steam via ${wrapper}"
    if [ -x "$wrapper" ]; then
        nohup "$wrapper" >/dev/null 2>&1 < /dev/null &
    elif [ -x "$real_steam" ]; then
        nohup "$real_steam" >/dev/null 2>&1 < /dev/null &
    fi
}

# Single inspection step
# Returns:
#   0 = No transition required (session is aligned)
#   1 = Transitioned to clean mode (unauthorized user quarantined)
#   2 = Transitioned to modded mode (authorized user restored)
watch_step() {
    local steam_root="${1:-$(find_steam_root)}"
    local vdf="$steam_root/config/loginusers.vdf"
    local authorized_id
    authorized_id="$(get_authorized_steamid "$GATEKEEPER_CONFIG" || true)"

    [ -f "$vdf" ] || return 0

    local active_id=""
    active_id="$(get_active_steamid "$vdf" || true)"
    [ -n "$active_id" ] || return 0

    local real_steam
    real_steam="$(find_real_steam)"
    local current_mode
    current_mode="$(get_current_session_mode "$steam_root")"

    # Case A: An unauthorized account is active
    if [ -n "$authorized_id" ] && [ "$active_id" != "$authorized_id" ]; then
        if [ "$current_mode" = "modded" ]; then
            log_watcher "QUARANTINE TRIGGER: Active user=${active_id} is unauthorized (expected ${authorized_id}) while in modded mode. Enforcing clean mode."
            manage_stplugin "hide" "$steam_root"
            restart_steam "clean" "$steam_root" "$real_steam"
            return 1
        fi
        return 0
    fi

    # Case B: The authorized account is active
    if [ -n "$authorized_id" ] && [ "$active_id" = "$authorized_id" ]; then
        if [ "$current_mode" = "clean" ]; then
            log_watcher "RESTORE TRIGGER: Active user=${active_id} is authorized (${authorized_id}) while in clean mode. Restoring modded mode."
            manage_stplugin "restore" "$steam_root"
            restart_steam "modded" "$steam_root" "$real_steam"
            return 2
        fi
        return 0
    fi

    return 0
}

# Continuous monitoring loop
run_watcher_daemon() {
    local steam_root
    steam_root="$(find_steam_root)"
    local vdf="$steam_root/config/loginusers.vdf"
    local interval="${WATCHER_INTERVAL:-2}"

    log_watcher "Watcher daemon started (PID=$$). Monitoring: ${vdf}"

    # PID file management
    mkdir -p "$WATCHER_STATE_DIR" 2>/dev/null || true
    printf '%s' "$$" > "$WATCHER_PIDFILE" 2>/dev/null || true
    trap 'rm -f "$WATCHER_PIDFILE" 2>/dev/null || true; exit 0' EXIT INT TERM

    local last_mtime=""
    while true; do
        if is_steam_running; then
            local cur_mtime=""
            if [ -f "$vdf" ]; then
                cur_mtime="$(stat -c %Y "$vdf" 2>/dev/null || stat -f %m "$vdf" 2>/dev/null || echo 0)"
            fi

            if [ "$cur_mtime" != "$last_mtime" ]; then
                last_mtime="$cur_mtime"
                watch_step "$steam_root" || true
            fi
        fi

        # Use inotifywait if available for instantaneous response, otherwise sleep
        if command -v inotifywait >/dev/null 2>&1 && [ -f "$vdf" ]; then
            inotifywait -q -t "$interval" -e modify,close_write,move "$vdf" >/dev/null 2>&1 || true
        else
            sleep "$interval"
        fi
    done
}

# Ensure watcher daemon is running (spawn once)
ensure_watcher_running() {
    if [ -f "$WATCHER_PIDFILE" ]; then
        local pid
        pid="$(cat "$WATCHER_PIDFILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # Already running and healthy
            return 0
        fi
    fi

    # Spawn daemon detached
    mkdir -p "$WATCHER_STATE_DIR" 2>/dev/null || true
    nohup "$0" --daemon >/dev/null 2>&1 < /dev/null &
    log_watcher "Spawned background watcher daemon"
}

main() {
    local action="${1:---daemon}"
    case "$action" in
        --daemon)
            run_watcher_daemon
            ;;
        --step)
            watch_step
            ;;
        --ensure)
            ensure_watcher_running
            ;;
        --trigger-clean)
            local root
            root="$(find_steam_root)"
            manage_stplugin "hide" "$root"
            restart_steam "clean" "$root" "$(find_real_steam)"
            ;;
        --trigger-modded)
            local root
            root="$(find_steam_root)"
            manage_stplugin "restore" "$root"
            restart_steam "modded" "$root" "$(find_real_steam)"
            ;;
        *)
            echo "Usage: $0 [--daemon|--step|--ensure|--trigger-clean|--trigger-modded]" >&2
            exit 1
            ;;
    esac
}

if [ "${WATCHER_LIB_ONLY:-0}" = 0 ]; then
    main "$@"
fi
