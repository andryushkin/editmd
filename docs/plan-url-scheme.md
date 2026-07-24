# Plan: `editmd://` URL scheme (web-clipper handoff)

Status: **implemented** — both sides ship. The app behaviour is documented in
[integration.md](integration.md) § `editmd://` URL scheme; this file is kept
for the reference research behind the design and records where the
implementation deviates from the original plan:

- `&content=` is **not** honoured as a body carrier yet (it stays reserved and
  ignored); without `&clipboard` the file is created empty.
- Destination decision (step 4): active workspace root, else
  `~/Documents/EditMD Clips`, overridable through the `clips.folder` user
  default — no Settings UI in v1.
- Extra guard the plan did not foresee: a launch caused by the URL delivers
  the open before `applicationDidFinishLaunching`, so the cold-launch editor
  mode reset is conditional — otherwise the clip opens in Preview.

## Goal

Let the webtodotmd Chrome extension (and any external tool) hand a captured
Markdown note to EditMD, following the Obsidian Web Clipper pattern: the
app registers a custom URL scheme; the note body travels through the system
clipboard, the URL carries only the file name and flags. Works cold-start —
macOS launches EditMD if it is not running (unlike the control socket).

## Reference behavior (Obsidian Web Clipper)

- Builds `obsidian://new?file=<name>&vault=<v>[&append=true|prepend=true|overwrite=true][&silent=true]`.
- Default transport: copies Markdown to the clipboard, appends `&clipboard` —
  the app reads the body from the pasteboard. `&content=` is used only as a
  legacy/fallback carrier (URL length limits).
- The extension opens the URL via `chrome.tabs.update(currentTab, { url })`;
  the page does not actually navigate (external protocol), macOS routes it
  to the app.

## URL contract (v1)

```
editmd://new?file=<name>&clipboard
```

- `file` — file name **without** extension, URL-encoded; the app appends
  `.md`. Already sanitized by the sender, but the app must re-sanitize
  (defense in depth: strip `/`, `\`, `:`, null bytes, leading dots; cap
  length ~100 chars; empty → `Clip`).
- `clipboard` (flag, no value) — body = general pasteboard string
  (`NSPasteboard.general.string(forType: .string)`). Empty/missing
  pasteboard → create the file with an empty body rather than failing.

Reserved for later, parse-tolerant now (unknown params are ignored):
`&content=<encoded md>` (direct carrier fallback), `&append=true`,
`&silent=true` (do not activate the app), `&workspace=<name>`.

## Implementation steps

1. **Info.plist** (`EditMD/EditMD/App/Info.plist`): add `CFBundleURLTypes`
   with `CFBundleURLSchemes: [editmd]`, `CFBundleURLName` = bundle id,
   `CFBundleTypeRole: Editor`.

2. **AppDelegate** (`App/AppDelegate.swift`, `application(_:open:)` at ~80):
   branch on `url.scheme == "editmd"` → `AppState.shared.handleURLCommand(url)`;
   everything else keeps going to `handleOpen` (Finder file opens).

3. **AppState.handleURLCommand(_ url: URL)** (`App/AppState.swift`):
   - Parse with `URLComponents`; command = `url.host` (`"new"` only in v1;
     unknown command → log + ignore).
   - Resolve target folder (see "Where clips land" below).
   - Body: pasteboard string when `clipboard` flag present, else `content`
     param, else empty.
   - Create the file; on name collision uniquify (`Name 2.md`, `Name 3.md`…)
     — **never overwrite** in v1.
   - Open via the existing `openCreatedFile(url)` (write-first Visual mode).

4. **Where clips land** (open product decision, pick at implementation):
   - v1 default: root of the active workspace; if no workspace is open,
     fall back to a `Clips` folder (created on demand) inside a settings-
     configurable location (default `~/Documents/EditMD Clips`).
   - Later: `&workspace=<name>` param as the analog of Obsidian's `&vault=`.

5. **Security** — any web page can trigger the scheme
   (`location.href = 'editmd://…'`), so:
   - `new` only creates files, never overwrites or deletes; uniquify always.
   - Re-sanitize `file` server-side; reject path traversal (no separators).
   - Never execute or interpret the body; it is written verbatim.
   - Rate/size sanity: cap body at a few MB.

6. **Tests**: unit-test the URL parser + name sanitizer + uniquifier
   (pure functions, no AppKit). Manual smoke:
   `open "editmd://new?file=Test%20Clip&clipboard"` with Markdown in the
   clipboard, app both running and quit.

## Extension side (already done, webtodotmd)

`src/sidepanel/sidepanel.ts` — "EditMD" toolbar button: copies `rawMd` to
the clipboard, then `chrome.tabs.update(activeTab, { url: 'editmd://new?file=<title>&clipboard' })`
with `window.open` fallback. i18n keys `tooltipSendEditmd` / `sentEditmd`
in all locales; telemetry event `send_editmd`. First use shows Chrome's
"Open EditMD?" confirmation — same as Obsidian.
