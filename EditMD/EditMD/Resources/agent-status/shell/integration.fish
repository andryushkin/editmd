# editmd-agent-status — fish integration for bare agent processes.
# Source from ~/.config/fish/config.fish.
#
#   set -g EDITMD_AGENT_RE '^(gemini|cursor-agent|my-agent)([[:space:]]|$)'

if not set -q EDITMD_ENABLED
    and not test -e "$HOME/Library/Application Support/EditMD/control.sock"
    return 0 2>/dev/null
end

set -l _ags_dir (dirname (dirname (status filename)))
if not set -q EDITMD_AGENT_BIN
    set -g EDITMD_AGENT_BIN "$_ags_dir/editmd-agent-status.sh"
end
if not set -q EDITMD_AGENT_RE
    set -g EDITMD_AGENT_RE '^(gemini|cursor-agent|aider|opencode|crush|goose)([[:space:]]|$)'
end

function _editmd_preexec --on-event fish_preexec
    if string match -r -q $EDITMD_AGENT_RE $argv[1]
        $EDITMD_AGENT_BIN active --harness shell
        set -g _editmd_agent_active 1
    end
end

function _editmd_precmd --on-event fish_prompt
    if set -q _editmd_agent_active
        $EDITMD_AGENT_BIN idle --harness shell
        set -e _editmd_agent_active
    end
end
