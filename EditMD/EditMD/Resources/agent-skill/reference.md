# editmdctl reference

Full command and protocol detail. See `SKILL.md` for the overview.

## Connection

- Socket: `~/Library/Application Support/EditMD/control.sock`
- Env: `EDITMD_CONTROL_SOCK` or `EDITMD_SOCKET` (EditMD injects the latter for ✈️ agents)
- Wire: one JSON request line → one JSON response line
- CLI: human output by default; `--json` for machine-readable

Request:

```json
{"id":"1","cmd":"open","args":{"path":"/abs/file.md","line":10}}
```

Response:

```json
{"id":"1","ok":true,"data":{"path":"/abs/file.md","offset":120}}
```

```json
{"id":"1","ok":false,"error":"file not found: …"}
```

## Commands

| CLI | Wire `cmd` | Notes |
|-----|------------|-------|
| `ping` | `ping` | `{pong:true}` |
| `status` | `status` | version, path, mode, dirty, ide, open marks |
| `open <path> [--line N \| --heading H]` | `open` | path must be absolute (ctl absolutizes) |
| `reveal [--path P] [--line N]` | `reveal` | jump caret / scroll |
| `mode source\|visual\|preview\|split` | `mode` | |
| `marks list [--path P] [--all]` | `marks.list` | open-only by default |
| `marks add --type T --note N [--quote Q]` | `marks.add` | selection used if no quote |
| `diff show [--path P]` | `diff.show` | buffer vs disk |
| `workspace add <path>` | `workspace.add` | adopt folder |
| `agent-status <state> [--label T] [--harness N]` | `agent-status` | `idle\|active\|completed\|blocked` |

## Sidecar: `*.review.json`

Path: for `note.md` → `note.md.review.json` next to the file.

Minimal mark fields (smotr-compatible, UTF-16 offsets):

- `id`, `type`, `status` (`open` / resolved variants)
- `quote`, optional `prefix`, `start` (UTF-16)
- `note`, `thread[]`, for suggests: `replacement`, optional `for` (parent id)

Agent suggestions: `type: "suggest"` with `quote` + `replacement`. User Accept goes through EditMD’s registry — do not raw-overwrite when the user expects Accept/Reject.

## Queue: `.smotr-queue.json`

At the workspace root. Shape:

```json
{
  "created": 1710000000000,
  "count": 2,
  "marks": [
    {"file": "docs/a.md", "kind": "md", "id": "…", "type": "comment", "status": "open"}
  ]
}
```

Log of the headless agent: `.smotr-agent.log` in the same root.

## agent-status

Maps to the ✨ toolbar face:

| state | UI |
|-------|-----|
| `idle` | clear / resting |
| `active` | working (pulse) |
| `completed` | finished toast |
| `blocked` | needs attention (badge) |

Always exit 0 from shell hooks; use `Resources/agent-status/editmd-agent-status.sh` which no-ops when EditMD is not running.
