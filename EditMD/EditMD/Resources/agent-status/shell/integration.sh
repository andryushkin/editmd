#!/usr/bin/env bash
# editmd-agent-status — bash/zsh integration for "bare" agent processes.
# Source from ~/.zshrc or ~/.bashrc.
#
# Override which commands count as agents:
#   export EDITMD_AGENT_RE='^(gemini|cursor-agent|my-agent)([[:space:]]|$)'
#
# Claude Code, Codex, and Pi are intentionally NOT in the default list — their
# own hooks drive finer state.

[ -n "${EDITMD_ENABLED:-}" ] || [ -S "${EDITMD_SOCKET:-$HOME/Library/Application Support/EditMD/control.sock}" ] || return 0 2>/dev/null

_editmd_status_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"
: "${EDITMD_AGENT_BIN:=$_editmd_status_dir/editmd-agent-status.sh}"
: "${EDITMD_AGENT_RE:=^(gemini|cursor-agent|aider|opencode|crush|goose)([[:space:]]|$)}"

_editmd_preexec() {
  if [[ "$1" =~ $EDITMD_AGENT_RE ]]; then
    "$EDITMD_AGENT_BIN" active --harness shell >/dev/null 2>&1 || true
    _EDITMD_AGENT_ACTIVE=1
  fi
}

_editmd_precmd() {
  if [ -n "${_EDITMD_AGENT_ACTIVE:-}" ]; then
    "$EDITMD_AGENT_BIN" idle --harness shell >/dev/null 2>&1 || true
    unset _EDITMD_AGENT_ACTIVE
  fi
}

# zsh
if [ -n "${ZSH_VERSION:-}" ]; then
  autoload -Uz add-zsh-hook 2>/dev/null || true
  add-zsh-hook preexec _editmd_preexec 2>/dev/null || true
  add-zsh-hook precmd _editmd_precmd 2>/dev/null || true
fi

# bash — no native preexec; a guarded DEBUG trap fills in (skipped when a
# DEBUG trap already exists so we never clobber bash-preexec or user traps).
if [ -n "${BASH_VERSION:-}" ]; then
  _editmd_bash_debug() {
    # Ignore completion, prompt-command re-entry, and our own hooks.
    [ -n "${COMP_LINE:-}" ] && return
    [ "${BASH_COMMAND}" = "${PROMPT_COMMAND:-}" ] && return
    case "$BASH_COMMAND" in _editmd_*) return ;; esac
    _editmd_preexec "$BASH_COMMAND"
  }
  if [ -z "$(trap -p DEBUG)" ]; then
    trap '_editmd_bash_debug' DEBUG
  fi
  # shellcheck disable=SC2034
  PROMPT_COMMAND="_editmd_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
