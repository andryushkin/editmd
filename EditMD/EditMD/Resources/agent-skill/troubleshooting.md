# Troubleshooting EditMD agent integration

## editmdctl: EditMD is not running

- Launch EditMD once (socket is created at app launch).
- Check: `ls "$HOME/Library/Application Support/EditMD/control.sock"`
- Override: `export EDITMD_CONTROL_SOCK=/tmp/editmd.sock` (must match the app).

## command not found: editmdctl

- Build the `editmdctl` target, or use Settings ▸ Integrations ▸ Install Command Line Tool
  (symlink into `/usr/local/bin` when permitted).
- Hooks resolve `$EDITMDCTL` first, then a path baked by the installer.

## marks add did nothing

- Need a selection in Source/Visual/Preview, or pass `--quote` + `--note`.
- Prefer **Preview** for review selection.
- File must be open in the main window for selection-based add.

## /ide does not attach

- Settings ▸ General ▸ Claude Code integration enabled.
- Run `claude` in a folder that is an EditMD workspace (or the active file’s folder).
- Type `/ide` in Claude Code. ✨ turns accent-colored when a client connects.

## Agent rewrote the file and EditMD shows a conflict

- Prefer `suggest` marks or openDiff Accept so writes go through
  `DocumentRegistry.applyAgentEdit`.
- Dirty buffer + disk change → conflict chip (by design).

## Hooks never update ✨

- Install hooks from Settings ▸ Integrations.
- Wrapper must be executable: `~/.config/editmd/agent-status/editmd-agent-status.sh`
- Always exits 0; if socket missing it is a silent no-op.
