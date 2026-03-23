#!/usr/bin/env bash
set -euo pipefail

SOCK_DIR="/tmp/ztach-oc"
OC_DB="$HOME/.local/share/opencode/opencode.db"

MAX_PATH=32
MAX_BRANCH=16
SHOW_ALL=0

C_GREEN='\033[32m'
C_RED='\033[31m'
C_YELLOW='\033[33m'
C_RESET='\033[0m'

_trunc() {
    local s="$1" max="$2"
    if [ "${#s}" -gt "$max" ]; then
        echo "…${s:$((${#s} - max + 1))}"
    else
        echo "$s"
    fi
}

_short_path() {
    local p="${1/#$HOME/\~}"
    _trunc "$p" "$MAX_PATH"
}

_short_branch() {
    local b="$1"
    if [ "${#b}" -gt "$MAX_BRANCH" ]; then
        echo "${b:0:$((MAX_BRANCH - 1))}…"
    else
        echo "$b"
    fi
}

declare -A _STATUS_CACHE=()

_preload_statuses() {
    _STATUS_CACHE=()
    [ -f "$OC_DB" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
    local line dir status
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        status="${line##*|}"
        dir="${line%|*}"
        [ -n "$dir" ] && _STATUS_CACHE["$dir"]="$status"
    done < <(sqlite3 "$OC_DB" "
        WITH ranked AS (
            SELECT s.directory,
                   json_extract(m.data, '\$.role') as role,
                   json_extract(m.data, '\$.time.completed') as completed,
                   COALESCE(json_extract(m.data, '\$.tokens.output'), 0) as tokens,
                   (strftime('%s','now') * 1000 - m.time_created) / 1000 as age,
                   ROW_NUMBER() OVER (PARTITION BY s.directory ORDER BY s.time_updated DESC) as rn
            FROM session s
            JOIN message m ON m.session_id = s.id
            WHERE m.id = (SELECT id FROM message WHERE session_id = s.id ORDER BY time_created DESC LIMIT 1)
        )
        SELECT directory,
            CASE
                WHEN role = 'assistant' AND completed IS NOT NULL AND completed != '' THEN 'idle'
                WHEN role = 'assistant' AND tokens > 0 THEN 'working'
                WHEN role = 'assistant' AND age > 5 THEN 'waiting'
                WHEN role = 'assistant' THEN 'working'
                ELSE 'unknown'
            END
        FROM ranked
        WHERE rn = 1;
    " 2>/dev/null)
}

_session_status() {
    echo "${_STATUS_CACHE[$1]:-unknown}"
}

_status_color() {
    case "$1" in
        working) printf '%b' "$C_GREEN" ;;
        waiting) printf '%b' "$C_RED" ;;
        idle)    printf '%b' "$C_YELLOW" ;;
        *)       ;;
    esac
}

_fmt_session() {
    local sock="$1" base ts full_path dir="" branch="" status color
    base="$(basename "$sock" .sock)"
    ts="${base##*@}"
    if [ -f "$sock.path" ]; then
        read -r dir < "$sock.path"
        full_path="$(_short_path "$dir")"
    else
        full_path="${base%%@*}"
    fi
    if [ -f "$sock.branch" ]; then
        local b; read -r b < "$sock.branch"
        branch=" [$(_short_branch "$b")]"
    fi
    local line="$full_path$branch  ($ts)"
    if [ -n "$dir" ]; then
        status="$(_session_status "$dir")"
        color="$(_status_color "$status")"
        if [ -n "$color" ]; then
            printf '%b%s%b\n' "$color" "$line" "$C_RESET"
            return
        fi
    fi
    echo "$line"
}

_sock_dir() {
    local sock="$1"
    [ -f "$sock.path" ] && { read -r _d < "$sock.path"; echo "$_d"; } || echo ""
}

_matches_cwd() {
    local sock="$1"
    if [ "$SHOW_ALL" -eq 1 ]; then return 0; fi
    local d
    d="$(_sock_dir "$sock")"
    [ "$d" = "$PWD" ]
}

_rm_session() { rm -f "$1" "$1.path" "$1.branch"; }

_each_sock() {
    local callback="$1" filter="${2:-none}" found=0
    for sock in "$SOCK_DIR"/*.sock; do
        [ -S "$sock" ] || continue
        if [ "$filter" = "cwd" ] && ! _matches_cwd "$sock"; then
            continue
        fi
        found=1
        "$callback" "$sock"
    done
    [ "$found" -eq 1 ]
}

_pick_sock() {
    local prompt="$1" filter="$2" entries=()
    _preload_statuses
    for sock in "$SOCK_DIR"/*.sock; do
        [ -S "$sock" ] || continue
        if [ "$filter" = "cwd" ] && ! _matches_cwd "$sock"; then
            continue
        fi
        entries+=("$(_fmt_session "$sock")"$'\t'"$sock")
    done
    if [ ${#entries[@]} -eq 0 ]; then
        if [ "$SHOW_ALL" -eq 1 ]; then
            echo "No sessions found." >&2
        else
            echo "No sessions in $(basename "$PWD")." >&2
        fi
        return 1
    fi
    local picked
    picked=$(printf '%s\n' "${entries[@]}" | fzf --ansi --select-1 --prompt="$prompt" --with-nth=1 --delimiter=$'\t') || return 1
    echo "$picked" | cut -f2
}

cmd_start() {
    local has_sessions=0
    for sock in "$SOCK_DIR"/*.sock; do
        [ -S "$sock" ] || continue
        _matches_cwd "$sock" || continue
        has_sessions=1
        break
    done
    if [ "$has_sessions" -eq 1 ]; then
        cmd_attach
    else
        cmd_create "$@"
    fi
}

cmd_create() {
    mkdir -p "$SOCK_DIR"
    local name sock branch
    name="$(basename "$PWD")@$(date +%d.%m\ %H:%M)"
    sock="$SOCK_DIR/$name.sock"
    echo "$PWD" > "$sock.path"
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) && echo "$branch" > "$sock.branch"
    ztach -A "$sock" -r winch opencode "$@"
    # Disable mouse tracking after detach — the app inside the pty
    # enabled it, but ztach doesn't restore terminal state on detach.
    printf '\033[?1006l\033[?1003l\033[?1000l'
}

cmd_list() {
    _preload_statuses
    _each_sock _fmt_session cwd || {
        if [ "$SHOW_ALL" -eq 1 ]; then
            echo "No sessions found."
        else
            echo "No sessions in $(basename "$PWD")."
        fi
    }
}

cmd_attach() {
    local sock
    sock=$(_pick_sock "attach> " cwd) || return 1
    if [ ! -S "$sock" ]; then
        echo "Socket gone." >&2
        _rm_session "$sock"
        return 1
    fi
    # Enable mouse mode on the attaching terminal before connecting.
    # ztach doesn't replay terminal state, so a new client (e.g. phone)
    # never sees the mouse-enable sequences the app originally sent.
    printf '\033[?1000h\033[?1003h\033[?1006h'
    trap 'printf "\033[?1006l\033[?1003l\033[?1000l"' EXIT
    ztach -a "$sock" -r winch
}

cmd_kill() {
    local sock
    sock=$(_pick_sock "kill> " none) || return 1
    _rm_session "$sock"
    echo "Removed $(basename "$sock" .sock)"
}

cmd_help() {
    echo "Usage: ochub [command] [options]"
    echo ""
    echo "Commands:"
    echo "  start | s      Attach if sessions exist, otherwise create"
    echo "  create | c     Always create a new session"
    echo "  list | ls      List sessions (current dir only)"
    echo "  attach | a     Attach to a session (current dir only; default: all)"
    echo "  kill           Kill a session (all sessions)"
    echo "  help           Show this help"
    echo ""
    echo "Options:"
    echo "  --all, -A      Show sessions from all directories"
}

# parse flags
args=()
for arg in "$@"; do
    case "$arg" in
        --all|-A) SHOW_ALL=1 ;;
        *)        args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

case "${1:-}" in
    start|s)    shift; cmd_start "$@" ;;
    create|c)   shift; cmd_create "$@" ;;
    ls|list)    cmd_list ;;
    attach|a)   cmd_attach ;;
    kill)       cmd_kill ;;
    help|-h|--help) cmd_help ;;
    "")         SHOW_ALL=1; cmd_attach ;;
    *)          echo "Unknown command: $1" >&2; cmd_help >&2; exit 1 ;;
esac
