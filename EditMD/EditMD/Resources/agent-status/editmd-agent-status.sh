#!/usr/bin/env bash
# editmd-agent-status — set EditMD's agent-activity indicator from any harness.
#
#   editmd-agent-status.sh active
#   editmd-agent-status.sh completed --label "reviewed marks"
#   editmd-agent-status.sh blocked --label "needs approval" --harness codex
#   editmd-agent-status.sh idle
#
# States: idle | active | completed | blocked.
# Optional args after the state are forwarded to editmdctl (e.g. --label, --harness).
#
# Outside EditMD (no control socket) this is a silent no-op and always exits 0,
# so hooks never block the agent turn. stdout/stderr are suppressed (Claude Code
# injects hook stdout into the prompt).
#
# editmdctl resolution:
#   1. $EDITMDCTL
#   2. path baked by the installer (EDITMDCTL_DEFAULT below)
#   3. `editmdctl` on PATH
set -u

# When EditMD spawned the agent it sets EDITMD_ENABLED=1. Hooks without that
# still work if the socket exists; we only hard-skip when nothing is available.
state=${1:-}
[ -n "$state" ] || exit 0
shift

EDITMDCTL_DEFAULT="${EDITMDCTL_DEFAULT:-editmdctl}"
ctl="${EDITMDCTL:-$EDITMDCTL_DEFAULT}"

# Prefer the app-injected socket when present.
socket_args=()
if [ -n "${EDITMD_SOCKET:-}" ]; then
  socket_args=(--socket "$EDITMD_SOCKET")
elif [ -n "${EDITMD_CONTROL_SOCK:-}" ]; then
  socket_args=(--socket "$EDITMD_CONTROL_SOCK")
fi

# No EditMD running → no-op.
sock_path="${EDITMD_SOCKET:-${EDITMD_CONTROL_SOCK:-$HOME/Library/Application Support/EditMD/control.sock}}"
if [ ! -S "$sock_path" ] && [ ! -e "$sock_path" ]; then
  exit 0
fi

"$ctl" "${socket_args[@]+"${socket_args[@]}"}" agent-status "$state" "$@" >/dev/null 2>&1 || true
exit 0
