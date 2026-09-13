#!/usr/bin/env bash

# A pane with no status file has no agent in it, so get_pane_status must report
# nothing rather than borrowing the session status. The session status is the
# max over its panes, so inheriting it marks every plain shell (and the sidebar
# pane itself) "working" whenever any other agent in the session is busy, and
# drags get_window_status up with it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR"

# Two windows: w0 holds a busy agent, w1 holds an idle agent beside a plain
# shell (%99, no status file) standing in for the sidebar pane.
cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-panes)
        case "${3:-}" in
            repo:0) printf '%%1\n' ;;
            repo:1) printf '%%2\n%%99\n' ;;
            -a|*)   printf 'repo\t%%1\nrepo\t%%2\nrepo\t%%99\n' ;;
        esac
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

echo "working" > "$STATUS_DIR/repo.status"
echo "working" > "$PANE_DIR/repo_%1.status"
echo "done"    > "$PANE_DIR/repo_%2.status"

assert_status() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" != "$expected" ]; then
        echo "Assertion failed: $label" >&2
        echo "Expected: [$expected]  Actual: [$actual]" >&2
        exit 1
    fi
}

eval "$(
    PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" bash -c '
        source "'"$REPO_DIR"'/scripts/lib/session-status.sh"
        printf "untracked=%q\n" "$(get_pane_status repo %99)"
        printf "busy=%q\n"      "$(get_pane_status repo %1)"
        printf "idle=%q\n"      "$(get_pane_status repo %2)"
        printf "w0=%q\n"        "$(get_window_status repo 0)"
        printf "w1=%q\n"        "$(get_window_status repo 1)"
    '
)"

assert_status "untracked pane should report no status" "" "$untracked"
assert_status "tracked busy pane should stay working" "working" "$busy"
assert_status "tracked idle pane should stay done" "done" "$idle"
assert_status "window holding the busy agent should be working" "working" "$w0"
assert_status "window holding only an idle agent should be done" "done" "$w1"

echo "untracked pane status scope checks passed"
