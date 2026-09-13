#!/usr/bin/env bash

# Shared selection helpers for sidebar and popup switcher targets.

[[ -n "${_SELECTION_TARGETS_LOADED:-}" ]] && return 0
_SELECTION_TARGETS_LOADED=1

selection_scope() {
    local sel_name="$1"
    local sel_type="$2"

    case "$sel_type" in
        S|W)
            echo "session"
            ;;
        P)
            local target="${sel_name#*:}"
            if [[ "$target" == w* ]]; then
                echo "window"
            else
                echo "pane"
            fi
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

selection_session() {
    local sel_name="$1"
    local sel_type="$2"

    case "$sel_type" in
        P)
            echo "${sel_name%%:*}"
            ;;
        *)
            echo "$sel_name"
            ;;
    esac
}

selection_token() {
    local sel_name="$1"
    local sel_type="$2"

    if [[ "$sel_type" == "P" ]]; then
        echo "${sel_name#*:}"
    else
        echo "$sel_name"
    fi
}

selection_window_index() {
    local sel_name="$1"
    local sel_type="$2"
    local scope token
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        window)
            echo "${token#w}"
            ;;
        pane)
            tmux display-message -p -t "$token" "#{window_index}" 2>/dev/null
            ;;
        session)
            tmux display-message -p -t "$(selection_session "$sel_name" "$sel_type")" "#{window_index}" 2>/dev/null
            ;;
    esac
}

selection_tmux_target() {
    local sel_name="$1"
    local sel_type="$2"
    local scope token session
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    token=$(selection_token "$sel_name" "$sel_type")
    session=$(selection_session "$sel_name" "$sel_type")

    case "$scope" in
        session)
            echo "$session"
            ;;
        window)
            echo "${session}:${token#w}"
            ;;
        pane)
            echo "$token"
            ;;
    esac
}

selection_requires_confirmation() {
    # Customized: close sessions/windows/panes immediately without a
    # confirmation prompt. Original behavior asked to confirm for any
    # non-pane scope: [ "$scope" != "pane" ].
    return 1
}

selection_label() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token window_index window_name
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        session)
            printf 'session %s' "$session"
            ;;
        window)
            window_index="${token#w}"
            window_name=$(tmux display-message -p -t "${session}:${window_index}" "#{window_name}" 2>/dev/null || true)
            if [ -n "$window_name" ]; then
                printf 'window %s:%s (%s)' "$session" "$window_index" "$window_name"
            else
                printf 'window %s:%s' "$session" "$window_index"
            fi
            ;;
        pane)
            window_index=$(tmux display-message -p -t "$token" "#{window_index}" 2>/dev/null || true)
            if [ -n "$window_index" ]; then
                printf 'pane %s in %s:%s' "$token" "$session" "$window_index"
            else
                printf 'pane %s' "$token"
            fi
            ;;
    esac
}

selection_close_prompt() {
    local sel_name="$1"
    local sel_type="$2"
    local scope label
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    label=$(selection_label "$sel_name" "$sel_type")

    case "$scope" in
        session)
            printf 'Close %s and all child windows and panes?' "$label"
            ;;
        window)
            printf 'Close %s and all child panes?' "$label"
            ;;
        pane)
            printf 'Close %s?' "$label"
            ;;
    esac
}

selection_list_panes() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        session)
            tmux list-panes -t "$session" -F "#{pane_id}" 2>/dev/null
            ;;
        window)
            tmux list-panes -t "${session}:${token#w}" -F "#{pane_id}" 2>/dev/null
            ;;
        pane)
            printf '%s\n' "$token"
            ;;
    esac
}

selection_includes_current_client() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token
    local current_session current_window current_pane

    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")
    current_session=$(tmux display-message -p "#{client_session}" 2>/dev/null || true)
    current_window=$(tmux display-message -p "#{window_index}" 2>/dev/null || true)
    current_pane=$(tmux display-message -p "#{pane_id}" 2>/dev/null || true)

    case "$scope" in
        session)
            [ "$session" = "$current_session" ]
            ;;
        window)
            [ "$session" = "$current_session" ] && [ "${token#w}" = "$current_window" ]
            ;;
        pane)
            [ "$token" = "$current_pane" ]
            ;;
        *)
            return 1
            ;;
    esac
}

# The sidebar pane of a window, and the first pane that is not one. A window
# row selects a window, not a pane, so switching to it alone leaves the cursor
# wherever that window last had it -- which, once every window has a sidebar,
# is usually the sidebar. Callers use these to say which of the two they want.
selection_window_sidebar_pane() {
    tmux list-panes -t "$1" -F '#{pane_id} #{pane_title}' 2>/dev/null \
        | awk '$2 == "agent-sidebar" { print $1; exit }'
}

selection_window_agent_pane() {
    tmux list-panes -t "$1" -F '#{pane_id} #{pane_title}' 2>/dev/null \
        | awk '$2 != "agent-sidebar" { print $1; exit }'
}

# focus: "agent" (default) puts the cursor on the window's non-sidebar pane;
# "sidebar" keeps it on the sidebar, for browsing without leaving the list.
selection_switch_client() {
    local sel_name="$1"
    local sel_type="$2"
    local focus="${3:-agent}"
    local scope session token win_idx target_win pane
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        pane)
            win_idx=$(tmux display-message -t "$token" -p "#{window_index}" 2>/dev/null || true)
            tmux switch-client -t "$session" 2>/dev/null
            [ -n "$win_idx" ] && tmux select-window -t "${session}:${win_idx}" 2>/dev/null
            if [ "$focus" = "sidebar" ] && [ -n "$win_idx" ]; then
                pane=$(selection_window_sidebar_pane "${session}:${win_idx}")
                tmux select-pane -t "${pane:-$token}" 2>/dev/null
            else
                tmux select-pane -t "$token" 2>/dev/null
            fi
            ;;
        window)
            target_win="${session}:${token#w}"
            tmux switch-client -t "$session" 2>/dev/null
            tmux select-window -t "$target_win" 2>/dev/null
            if [ "$focus" = "sidebar" ]; then
                pane=$(selection_window_sidebar_pane "$target_win")
            else
                pane=$(selection_window_agent_pane "$target_win")
            fi
            if [ -n "$pane" ]; then
                tmux select-pane -t "$pane" 2>/dev/null
            fi
            ;;
        session)
            tmux switch-client -t "$session" 2>/dev/null
            ;;
    esac
    # Every branch ends in a best-effort tmux call, and a window with no
    # matching pane leaves $pane empty. Callers (next-done-project.sh) run
    # under set -e, so settle the status explicitly rather than leaking the
    # last command's.
    return 0
}
