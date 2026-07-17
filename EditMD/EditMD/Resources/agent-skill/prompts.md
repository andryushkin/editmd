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

## Connect / discover EditMD

```
You are helping inside EditMD. Prefer editmdctl (control socket) for open/mode/marks.
If Claude Code is available, the user can also run /ide for live selection and openDiff.
Install skill: Help ▸ Install Agent Skill… in EditMD. Then: editmdctl status
```
