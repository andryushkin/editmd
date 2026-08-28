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
| `status` | `status` | version, path, mode, dirty, ide, open marks, `core` (`abi`/`expected`/`verdict`) |
| `open <path> [--line N \| --heading H]` | `open` | path must be absolute (ctl absolutizes) |
| `reveal [--path P] [--line N]` | `reveal` | jump caret / scroll |
| `mode source\|visual\|preview\|split` | `mode` | |
| `marks list [--path P] [--all]` | `marks.list` | open-only by default |
| `marks add --type T --note N [--quote Q]` | `marks.add` | selection used if no quote |
| `diff show [--path P]` | `diff.show` | buffer vs disk |
| `workspace add <path>` | `workspace.add` | adopt folder |
| `agent-status <state> [--label T] [--harness N]` | `agent-status` | `idle\|active\|completed\|blocked` |
| `index status` | `index.status` | readiness, scope, counters, persisted age |
| `index rebuild [root]` | `index.rebuild` | **offline-only**; refuses while EditMD runs |
| `links outgoing [path]` | `links.outgoing` | per link: status `resolved\|dead\|ambiguous\|external` |
| `links backlinks [path]` | `links.backlinks` | reverse edges: source, line, offset, context |
| `links resolve <target> [--from P]` | `links.resolve` | navigation rules; sibling of `--from` wins ties |
| `outline [path]` | `outline` | headings: level, title, UTF-16 offset |
| `lint workspace [--limit N]` | `lint.workspace` | findings: rule, severity, target, suggestion |
| `lint file [path]` | `lint.file` | per-file findings (no orphan rule) |
| `tags list` | `tags.list` | tag → file count |
| `tags files <tag>` | `tags.files` | leading `#` optional |
| `frontmatter get [path]` | `frontmatter.get` | `present`, `raw`, ordered `properties` |
| `search <query> [--limit N]` | `search` | tokens, "phrases", `path:` / `#tag` filters |

Vault-graph commands answer for the ACTIVE workspace when EditMD runs
(`outside-active-workspace` otherwise; `link index not ready (indexing N%)`
while it builds — retry). A path-based command on a file that does not exist
returns `file not found: …` (same token online and offline — never an empty
success payload). Without EditMD the offline engine serves the same commands
from disk (see SKILL.md). Global flags: `--json`, `--socket PATH`,
`--root PATH` (offline root override).

## Persisted index: `.editmd/link-index.json`

At the workspace root; written atomically by EditMD after every full scan
and by the offline engine after every query. Self-gitignored
(`.editmd/.gitignore` contains `*`). Safe to read directly when EditMD is
not running; treat it as a cache — the commands revalidate it for you.

```json
{
  "version": 1,
  "scannedAt": "2026-07-19T09:00:00Z",
  "files": [
    {
      "path": "notes/alpha.md",
      "mtimeBits": 13957167715869402000,
      "size": 120,
      "headings": ["Alpha"],
      "resolveFingerprint": 7063790126886096978,
      "links": [
        {"kind": "wiki", "rawTarget": "beta", "label": "beta",
         "line": 3, "utf16Offset": 10, "context": "[[beta]]",
         "resolvedPath": "beta.md", "candidatePaths": ["beta.md"]}
      ]
    }
  ]
}
```

- All paths are RELATIVE to the workspace root (the vault is portable).
- `mtimeBits` / `resolveFingerprint` are opaque cache-validity fields —
  never compute or compare them yourself.
- A missing `resolvedPath` on a `links` entry means unresolved (dead) or
  the resolution was not cacheable; run `links outgoing` for live status.
- Unknown `version` → ignore the file and use the commands.

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
    {"file": "notes/a.md", "kind": "md", "id": "…", "type": "comment", "status": "open"}
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
