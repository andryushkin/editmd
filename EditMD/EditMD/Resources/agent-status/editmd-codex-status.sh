#!/usr/bin/env bash
# Codex lifecycle adapter for EditMD agent-status.
# PermissionRequest fires before Auto Review — do NOT map it directly to
# blocked (agterm lesson). Map turn start → active, turn end → completed.
set -u

action=${1:-}
[ -n "$action" ] || exit 0
shift

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
wrapper=${EDITMD_STATUS_WRAPPER:-"$script_dir/editmd-agent-status.sh"}

case "$action" in
  turn-start|agent-start|SessionStart)
    "$wrapper" active --harness codex "$@" >/dev/null 2>&1 || true
    ;;
  turn-end|agent-end|Stop|completed)
    "$wrapper" completed --harness codex "$@" >/dev/null 2>&1 || true
    ;;
  blocked|needs-input)
    # Only when the harness truly needs a human (after Auto Review).
    "$wrapper" blocked --label "needs input" --harness codex "$@" >/dev/null 2>&1 || true
    ;;
  idle)
    "$wrapper" idle --harness codex >/dev/null 2>&1 || true
    ;;
  *)
    # Unknown lifecycle events are ignored.
    ;;
esac
exit 0
