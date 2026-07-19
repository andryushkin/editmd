# Prompt templates (single source with ✨ palette)

These are the same intents as `AgentPromptCatalog` in the app. Substitute
`{{FILE}}`, `{{WORKSPACE}}`, `{{OPEN_MARKS}}`.

## Process review queue

```bash
cd '{{WORKSPACE}}' && claude -p "/smotr -pr"
```

## Review active file

```
Review this markdown file in EditMD and leave open review marks via editmdctl
(types: question|fix|rewrite|cut|keep|comment). Do not rewrite the file directly
when a suggest mark is enough.

File: {{FILE}}
Workspace: {{WORKSPACE}}

Commands:
  editmdctl open '{{FILE}}'
  editmdctl marks list --path '{{FILE}}'
  editmdctl marks add --type comment --note "…"
```

## Work the vault graph

```
You are working in a wikillm-style markdown vault that EditMD indexes. Do NOT
grep/walk the vault to build the link graph yourself — ask EditMD:
  editmdctl index status | links outgoing/backlinks/resolve | outline |
  lint workspace/file | tags list/files | frontmatter get | search
If EditMD is not running, the same commands answer from the offline engine
(--root {{WORKSPACE}} if no .editmd/.obsidian marker). Details: editmd skill
reference.md.

Workspace: {{WORKSPACE}}
```

## Connect / discover EditMD

```
You are helping inside EditMD. Prefer editmdctl (control socket) for open/mode/marks.
If Claude Code is available, the user can also run /ide for live selection and openDiff.
Install skill: Help ▸ Install Agent Skill… in EditMD. Then: editmdctl status
```
