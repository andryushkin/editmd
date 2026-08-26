import Foundation

// MARK: - Full page for Preview's WKWebView

/// Rendered Preview page + whether the shell embeds the KaTeX assets. The live
/// `innerHTML` path needs the bit to reload when a document grows its first
/// formula, and it must come from the render, not a rescan: `markdownHTMLRender`
/// strips frontmatter before looking for math, so `$…$` there would claim
/// assets the page never received and later formulas would stay raw TeX.
struct PreviewPageRender {
    let html: String
    let hasMathAssets: Bool
}

/// Wraps the rendered body in a standalone page, and says whether the shell
/// embedded its KaTeX assets (see `PreviewPageRender`). `color-scheme` + CSS
/// system colors track light/dark without reloading; body font size and padding
/// mirror the editor's `textContainerInset` so toggling edit↔preview doesn't
/// jump.
func previewHTMLPageRender(markdown: String,
                           fontSize: CGFloat,
                           insetH: CGFloat = 32,
                           /// Top (and minimum bottom) page padding — Settings ▸ Vertical.
                           insetV: CGFloat = 24,
                           lineHeight: CGFloat = 1.6,
                           /// Centered reading column; `0` = full width aligned
                           /// to `insetH` (matches the editor inset).
                           columnWidth: CGFloat = 0,
                           fontFamily: String = "-apple-system, \"Helvetica Neue\", sans-serif",
                           fontWeight: Int = 400,
                           elements: ElementStyles = ElementStyles(),
                           /// Base text / link hex overrides; nil keeps adaptive
                           /// system colors (Canvas/CanvasText/LinkText).
                           textColorHex: String? = nil,
                           accentColorHex: String? = nil,
                           /// `PreviewTheme.css` layer: base < theme < user.
                           themeCSS: String = "",
                           gutter: PreviewGutterOptions = .off,
                           syntaxHighlighting: Bool = true,
                           imageResolver: ((String) -> String?)? = nil) -> PreviewPageRender {
    let (body, hasMath) = markdownHTMLRender(markdown, imageResolver: imageResolver,
                                             gutter: gutter,
                                             syntaxHighlighting: syntaxHighlighting)
    // KaTeX is ~640 KB inline — embedded only when the document has math;
    // without assets `.math` spans show raw TeX.
    let mathAssets = hasMath && KaTeXResources.isAvailable
    let mathHead = mathAssets ? "<style>\n\(KaTeXResources.css)\n</style>" : ""
    // CSP: markdown is untrusted input; Preview is a viewer, not a script host.
    // Nonce'd script-src enforces it — shell scripts carry the nonce; raw-HTML
    // `<script>` and inline handlers (`<img onerror=…>`, the vector
    // `previewSafeRawHTML` alone cannot reach) never run. Verified: WKUserScript
    // and evaluateJavaScript are host-privileged and bypass CSP; `el.onclick =
    // fn` from our script still works — only handlers parsed from markup are
    // blocked. Styles stay 'unsafe-inline' (inline CSS + hljs `--tl:` tokens).
    let scriptNonce = UUID().uuidString
    let csp = "default-src 'none'; "
        + "img-src data: https: http:; media-src data: https: http:; "
        + "style-src 'unsafe-inline'; font-src data:; "
        + "script-src 'nonce-\(scriptNonce)'"
    // Library sits outside #preview-content so live innerHTML swaps cannot
    // remove it; newly inserted math renders via the shared hydrate function.
    let mathScripts = mathAssets ? """
    <script nonce="\(scriptNonce)">
    \(KaTeXResources.js)
    </script>
    """ : ""
    let maxWidth = columnWidth > 0 ? "\(Int(columnWidth))px" : "none"
    let margin = columnWidth > 0 ? "0 auto" : "0"
    let bodyColor = textColorHex ?? "CanvasText"
    let accentColor = accentColorHex ?? "LinkText"
    // Top is exactly insetV (strip→title gap matches Source/Visual); bottom
    // keeps a scroll pad when Vertical is small.
    let padTop = Int(insetV.rounded())
    let padBottom = Int(max(64, insetV).rounded())
    let padH = Int(insetH.rounded())
    let gutterOn = gutter.isVisible
    // Same digit size as Source/Visual ruler (`GutterTypography.fontSize`).
    let lnFontPx = Int(GutterTypography.fontSize.rounded())
    let lnColPx = Int(PreviewGutterMetrics.columnPx(for: gutter))
    let dirtyColor = gutter.dirtyMarkColorHex.isEmpty ? "#1a8f3c" : gutter.dirtyMarkColorHex
    let bodyGutterClass = gutterOn ? " class=\"\(gutter.modeClass)\"" : ""
    // Extra left padding reserves one shared gutter plus a comfortable gap.
    let lineNumberGapPx = Int(PreviewGutterMetrics.gapPx)
    let padHLeft = padH + Int(PreviewGutterMetrics.railPx(for: gutter))

    // ElementStyles rules appended after base AND theme so they win. Heading
    // size in `em`, matching Visual's base-size multiply. Default values emit
    // nothing — silence lets a theme restyle untouched elements.
    func numstr(_ v: CGFloat) -> String { String(format: "%.4g", v) }
    let defaultElements = ElementStyles()
    var elementCSS = ""
    for level in 1...6 {
        let e = elements.heading(level)
        let d = defaultElements.heading(level)
        var decl = ""
        if e.sizeScale != d.sizeScale { decl += "font-size: \(numstr(e.sizeScale))em;" }
        if let w = e.weight, w != d.weight { decl += " font-weight: \(w.cssValue);" }
        if let c = e.colorHex { decl += " color: \(c);" }
        if !decl.isEmpty {
            elementCSS += "h\(level) { \(decl.trimmingCharacters(in: .whitespaces)) }\n"
        }
    }
    var boldDecl = ""
    if let w = elements.bold.weight, w != defaultElements.bold.weight {
        boldDecl += "font-weight: \(w.cssValue);"
    }
    if let c = elements.bold.colorHex { boldDecl += " color: \(c);" }
    if !boldDecl.isEmpty {
        elementCSS += "strong, b { \(boldDecl.trimmingCharacters(in: .whitespaces)) }\n"
    }
    if let c = elements.inlineCode.colorHex { elementCSS += "code { color: \(c); }\n" }
    if let c = elements.link.colorHex ?? accentColorHex { elementCSS += "a { color: \(c); }\n" }
    if let c = elements.quote.colorHex { elementCSS += "blockquote { color: \(c); opacity: 1; }\n" }

    let html = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="\(csp)">
    <style>
    :root {
        color-scheme: light dark;
        --ln-dirty: \(dirtyColor);
        --ln-col: \(lnColPx)px;
        --ln-size: \(lnFontPx)px;
        --ln-gap: \(lineNumberGapPx)px;
        --accent: \(accentColor);
    }
    * { box-sizing: border-box; }
    /* WebKit's native scroll anchoring races our split-view restoration after
       innerHTML replacement and produces a visible up/down twitch. The Preview
       owns anchoring explicitly below. */
    html, body, #preview-content { overflow-anchor: none; }
    body {
        font: \(fontWeight) \(Int(fontSize))px/\(numstr(lineHeight)) \(fontFamily);
        background: Canvas; color: \(bodyColor);
        max-width: \(maxWidth); margin: \(margin); padding: \(padTop)px \(padH)px \(padBottom)px \(padHLeft)px;
        word-wrap: break-word;
        position: relative;
    }
    /* Integrated source-line gutter in the left padding. Fixed small mono size
       (not 1em) so headings don't blow up the numbers. */
    [data-ln] { position: relative; }
    [data-ln]::before {
        position: absolute;
        top: 0.2em;
        /* JS below replaces this fallback with a document-global x position.
           Every element has a different local origin (lists, quotes, tables),
           so a percentage/right-based gutter cannot form one visual column. */
        left: var(--ln-left, calc(-1 * (var(--ln-col) + var(--ln-gap))));
        width: var(--ln-col);
        text-align: right;
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: var(--ln-size);
        font-weight: 400;
        font-variant-numeric: tabular-nums;
        color: rgba(128,128,128,0.7);
        line-height: 1.2;
        user-select: none;
        pointer-events: none;
        white-space: nowrap;
    }
    /* Headings: pin number to the first text line, not the block center. */
    h1[data-ln]::before, h2[data-ln]::before, h3[data-ln]::before,
    h4[data-ln]::before, h5[data-ln]::before, h6[data-ln]::before {
        top: 0.35em;
        font-size: var(--ln-size);
        font-weight: 400;
    }
    body.gutter-numbers [data-ln]::before { content: attr(data-ln); }
    body.gutter-bullets [data-ln].ln-dirty::before {
        content: "●";
        color: var(--ln-dirty);
        font-size: calc(var(--ln-size) * 0.7);
    }
    body.gutter-bullets [data-ln]:not(.ln-dirty)::before { content: none; }
    [data-ln].ln-dirty::before {
        color: var(--ln-dirty);
        font-weight: 700;
    }
    /* First block must not add extra top margin on top of body padding —
       otherwise Settings ▸ Vertical never reaches zero under the action strip. */
    #preview-content > :first-child { margin-top: 0; }
    /* Sizes/weights mirror the ElementStyles defaults — the element CSS layer
       below only emits what the user changed, so these ARE the defaults. */
    h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 1.4em 0 0.5em; }
    h1 { font-size: 1.8em; font-weight: 700; } h2 { font-size: 1.5em; } h3 { font-size: 1.3em; }
    h4 { font-size: 1.1em; } h5 { font-size: 1em; } h6 { font-size: 0.9em; opacity: 0.7; }
    h1, h2 { border-bottom: 1px solid rgba(128,128,128,0.3); padding-bottom: 0.3em; }
    p { margin: 0.6em 0; }
    a { color: LinkText; text-decoration: none; }
    a:hover { text-decoration: underline; }
    a.wikilink { cursor: pointer; }
    code {
        font: 0.9em ui-monospace, "SF Mono", Menlo, monospace;
        background: rgba(128,128,128,0.15);
        border-radius: 4px; padding: 0.15em 0.35em;
    }
    pre {
        background: rgba(175,82,222,0.09);
        border: 1px solid rgba(175,82,222,0.28);
        border-radius: 8px; padding: 14px 16px;
        /* NOT overflow-x here: that clips the gutter number, which is an
           absolutely-positioned ::before sitting left of the block. The code
           itself scrolls instead. */
        overflow: visible;
    }
    pre code {
        background: none; padding: 0; font-size: 0.875em;
        display: block; overflow-x: auto;
    }
    blockquote {
        margin: 0.8em 0; padding: 0.1em 1em;
        border-left: 4px solid rgba(0,122,255,0.68);
        border-radius: 0 7px 7px 0;
        background: rgba(0,122,255,0.07);
        opacity: 0.9;
    }
    blockquote.callout {
        --callout-rgb: 0,122,255;
        position: relative;
        border-left-color: rgb(var(--callout-rgb));
        background: rgba(var(--callout-rgb),0.09);
        padding-left: 2.2em;
        opacity: 1;
    }
    blockquote.callout-tip { --callout-rgb: 40,160,80; }
    blockquote.callout-warning { --callout-rgb: 230,126,34; }
    blockquote.callout-important { --callout-rgb: 175,82,222; }
    blockquote.callout-example { --callout-rgb: 88,86,214; }
    .callout-icon {
        position: absolute; left: 0.72em; top: 0.72em;
        color: rgb(var(--callout-rgb)); font-weight: 700;
    }
    ul, ol { padding-left: 1.7em; margin: 0.6em 0; }
    li { margin: 0.2em 0; }
    li > p { margin: 0.2em 0; }
    li.task { list-style: none; margin-left: -1.35em; }
    li.task input { margin-right: 0.4em; vertical-align: -0.1em; }
    .multi-checkbox {
        appearance: none; border: 0; background: transparent; color: var(--accent);
        font: inherit; line-height: 1; padding: 0 0.18em; margin: 0 0.18em 0 0;
        cursor: pointer; vertical-align: -0.08em;
    }
    .multi-checkbox:not(:disabled):hover { background: rgba(128,128,128,0.13); border-radius: 4px; }
    .multi-checkbox:disabled { cursor: default; }
    .multi-checkbox:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
    .multi-checkbox-sf { width: 1em; height: 1em; object-fit: contain; vertical-align: -0.12em; }
    li.multi-task-strike { text-decoration: line-through; opacity: 0.68; }
    li.multi-task-strike > .multi-checkbox { text-decoration: none; opacity: 1; }
    hr { border: none; border-top: 2px solid rgba(128,128,128,0.3); margin: 1.6em 0; }
    table { border-collapse: collapse; margin: 1em 0; display: block; overflow-x: auto; }
    th, td { border: 1px solid rgba(128,128,128,0.35); padding: 6px 13px; }
    th { font-weight: 600; }
    tbody tr:nth-child(odd) { background: rgba(128,128,128,0.07); }
    img { max-width: 100%; }
    del { opacity: 0.6; }
    mark {
        background: rgba(255, 212, 0, 0.45);
        color: inherit;
        border-radius: 2px;
        padding: 0 0.12em;
    }
    /* ⌘F find (sprint 5): every match gets a soft wash, the active one a
       stronger fill. Wrapping spans are injected/removed by editMDFind and
       never touch the markdown source. */
    .editmd-find {
        background: rgba(255, 214, 10, 0.40);
        border-radius: 2px;
    }
    .editmd-find-current {
        background: rgba(255, 149, 0, 0.85);
        color: #1d1d1f;
        border-radius: 2px;
    }
    @media (prefers-color-scheme: dark) {
        mark { background: rgba(255, 196, 0, 0.35); }
        .editmd-find { background: rgba(255, 214, 10, 0.30); }
        .editmd-find-current { background: rgba(255, 159, 10, 0.90); color: #1d1d1f; }
        pre {
            background: rgba(191,90,242,0.12);
            border-color: rgba(191,90,242,0.36);
        }
        blockquote {
            background: rgba(10,132,255,0.11);
            border-left-color: rgba(10,132,255,0.78);
        }
        blockquote.callout { background: rgba(var(--callout-rgb),0.14); }
    }
    /* Review-mark wash (v37) — open smotr anchors painted over data-md-lo spans.
       Preview is the primary review surface; Source/Visual washes are secondary. */
    [data-md-lo].review-wash {
        border-radius: 2px;
        box-decoration-break: clone;
        -webkit-box-decoration-break: clone;
    }
    [data-md-lo].review-question { background: rgba(0, 122, 255, 0.18); }
    [data-md-lo].review-fix { background: rgba(255, 149, 0, 0.18); }
    [data-md-lo].review-rewrite { background: rgba(175, 82, 222, 0.18); }
    [data-md-lo].review-cut { background: rgba(255, 59, 48, 0.16); }
    [data-md-lo].review-keep { background: rgba(142, 142, 147, 0.18); }
    [data-md-lo].review-comment { background: rgba(255, 204, 0, 0.22); }
    [data-md-lo].review-suggest { background: rgba(52, 199, 89, 0.18); }
    [data-md-lo].review-wash.review-flash {
        outline: 2px solid rgba(0, 122, 255, 0.55);
        outline-offset: 1px;
    }
    /* Math ($…$ / $$…$$): KaTeX replaces the span content when its assets are
       embedded; before/without that the span shows the raw TeX source.
       Display blocks are LEFT-aligned with an indent (not centered) — and
       KaTeX's own .katex-display centering is overridden to match. */
    .math-display {
        display: block;
        text-align: left;
        padding-left: 2em;
        /* Bigger than the 0.6em paragraph margin it collapses with, so a
           display block gets real air instead of reading as one more line. */
        margin: 1.1em 0;
        overflow-x: auto;
        overflow-y: hidden;
    }
    .math-display .katex-display {
        text-align: left;
        /* overflow-x above makes .math-display a BFC — this margin would add
           to the outer one instead of collapsing into it. */
        margin: 0;
    }
    .math-display .katex-display > .katex {
        text-align: left;
    }
    .math-error {
        color: #cb2431;
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: 0.9em;
    }
    /* D4: copy button on code / quote (hover) */
    .copy-host { position: relative; }
    .copy-block-btn {
        position: absolute;
        top: 6px;
        right: 6px;
        z-index: 2;
        opacity: 0.72;
        pointer-events: auto;
        border: none;
        min-width: 32px;
        min-height: 32px;
        border-radius: 7px;
        padding: 4px 8px;
        font: 17px/1 ui-monospace, Menlo, monospace;
        background: rgba(128,128,128,0.18);
        color: inherit;
        cursor: pointer;
        transition: opacity 0.12s ease;
    }
    .copy-host:hover > .copy-block-btn { opacity: 1; }
    .copy-block-btn:hover { background: rgba(128,128,128,0.32); }
    /* Code tokens carry both palettes (--tl / --td); the page picks one, so a
       Dark Mode switch needs no re-render. */
    \(CodeSyntaxHighlighter.tokenCSS)
    \(themeCSS)
    \(elementCSS)</style>
    \(mathHead)
    </head>
    <body\(bodyGutterClass)>
    <main id="preview-content">\(body)</main>
    \(mathScripts)
    <script nonce="\(scriptNonce)">
    window.editMDPreviewRevision = 0;
    // Align every source-line marker to one document-global column. `data-ln`
    // lives on blocks with different local x origins (nested lists/quotes), so
    // pure element-relative CSS produces a ragged gutter. Recompute on resize
    // because a centered reading column moves with the viewport.
    function alignLineNumberGutter() {
        var bodyStyle = getComputedStyle(document.body);
        var contentLeft = document.body.getBoundingClientRect().left
            + parseFloat(bodyStyle.paddingLeft || '0');
        var rootStyle = getComputedStyle(document.documentElement);
        var columnWidth = parseFloat(rootStyle.getPropertyValue('--ln-col')) || 28;
        var gap = parseFloat(rootStyle.getPropertyValue('--ln-gap')) || 18;
        var desiredLeft = contentLeft - gap - columnWidth;
        document.querySelectorAll('[data-ln]').forEach(function (el) {
            var localLeft = desiredLeft - el.getBoundingClientRect().left;
            el.style.setProperty('--ln-left', localLeft + 'px');
        });
    }
    window.addEventListener('resize', alignLineNumberGutter);
    window.alignLineNumberGutter = alignLineNumberGutter;
    // Interactive task checkboxes (FSNotes' HandlerCheckbox idea): the body
    // fragment renders them disabled; the live preview re-enables them and
    // reports the clicked index — document order matches the order of
    // taskListMarker spans, which the Swift side uses to edit the source.
    function hydrateTaskCheckboxes() {
        document.querySelectorAll('li.task > input[type=checkbox]').forEach(function (box, i) {
            box.disabled = false;
            // Property assignment is deliberately idempotent: hydrate can run
            // after every fragment replacement without accumulating listeners.
            box.onchange = function () {
                var handlers = window.webkit && window.webkit.messageHandlers;
                if (handlers && handlers.taskToggle) { handlers.taskToggle.postMessage(i); }
            };
        });
    }
    // Built-in plugins use source offsets rather than document-order indexes:
    // a delayed click is rejected safely if the token moved meanwhile.
    function hydrateBuiltInPluginTokens() {
        document.querySelectorAll('button.multi-checkbox:not(:disabled)').forEach(function (button) {
            button.onclick = function (event) {
                event.preventDefault();
                var handlers = window.webkit && window.webkit.messageHandlers;
                var offset = Number(button.dataset.pluginOffset);
                if (handlers && handlers.builtInPluginToggle && Number.isFinite(offset)) {
                    handlers.builtInPluginToggle.postMessage(offset);
                }
            };
        });
    }
    // Wiki-link navigation: report a click; the Swift side resolves target →
    // file and opens it. Handler may be absent (no-op) until wired.
    function hydrateWikiLinks() {
        document.querySelectorAll('a.wikilink').forEach(function (el) {
            el.onclick = function (e) {
                e.preventDefault();
                var handlers = window.webkit && window.webkit.messageHandlers;
                if (handlers && handlers.wikiLinkClick) {
                    handlers.wikiLinkClick.postMessage({
                        target: el.dataset.wikiTarget,
                        heading: el.dataset.wikiHeading || null,
                        blockID: el.dataset.wikiBlock || null
                    });
                }
            };
        });
    }
    // Local file links ([pdf](/research_pdf/x.pdf)): schemeless hrefs cannot
    // resolve against loadHTMLString's about:blank base, so report the raw
    // href; the Swift side resolves it Obsidian-style (vault-absolute /
    // file-relative) and opens the target. Scheme links keep the default
    // navigation path (decidePolicyFor → system).
    function hydrateLocalLinks() {
        document.querySelectorAll('a[href]').forEach(function (el) {
            if (el.classList.contains('wikilink')) return;
            var href = el.getAttribute('href');
            if (!href || href.charAt(0) === '#' || /^[a-zA-Z][a-zA-Z0-9+.\\-]*:/.test(href)) return;
            el.onclick = function (e) {
                e.preventDefault();
                var handlers = window.webkit && window.webkit.messageHandlers;
                if (handlers && handlers.localLinkClick) {
                    handlers.localLinkClick.postMessage({ href: href });
                }
            };
        });
    }
    // Review marks (v37): paint open anchors on tagged spans and jump by
    // markdown UTF-16 offset. Called from Swift after load / mark changes.
    // marks = [{start, end, type, id}]
    window.applyReviewMarks = function (marks) {
        var types = ['question','fix','rewrite','cut','keep','comment','suggest'];
        document.querySelectorAll('[data-md-lo].review-wash').forEach(function (el) {
            el.classList.remove('review-wash', 'review-flash');
            types.forEach(function (t) { el.classList.remove('review-' + t); });
            el.removeAttribute('data-review-id');
            el.removeAttribute('title');
        });
        if (!marks || !marks.length) return;
        // `pre` carries data-md-lo for scroll sync only. Washing it would paint
        // the whole code block for a mark that touches one line of it, so the
        // wash stays on the inline spans, as before code blocks were tagged.
        document.querySelectorAll('[data-md-lo]:not(pre)').forEach(function (el) {
            var lo = parseInt(el.getAttribute('data-md-lo'), 10);
            var hi = parseInt(el.getAttribute('data-md-hi'), 10);
            if (isNaN(lo) || isNaN(hi)) return;
            for (var i = 0; i < marks.length; i++) {
                var m = marks[i];
                if (hi > m.start && lo < m.end) {
                    el.classList.add('review-wash', 'review-' + (m.type || 'comment'));
                    el.setAttribute('data-review-id', m.id || '');
                    if (m.tip) el.setAttribute('title', m.tip);
                    break; // first matching mark wins (worklist order)
                }
            }
        });
    };
    // Scroll the span covering `offset` into view; fraction fallback is Swift-side.
    window.scrollToMdOffset = function (offset) {
        // A span CONTAINING the offset always beats the nearest-preceding
        // fallback — a later non-containing span must not override it.
        var contain = null, containLo = -1, near = null, nearLo = -1;
        document.querySelectorAll('[data-md-lo]').forEach(function (el) {
            var lo = parseInt(el.getAttribute('data-md-lo'), 10);
            var hi = parseInt(el.getAttribute('data-md-hi'), 10);
            if (isNaN(lo) || isNaN(hi)) return;
            if (lo <= offset && offset < hi) {
                if (lo > containLo) { contain = el; containLo = lo; }
            } else if (lo <= offset && lo > nearLo) {
                near = el; nearLo = lo;
            }
        });
        var best = contain || near;
        if (best) {
            best.scrollIntoView({ block: 'center', behavior: 'smooth' });
            best.classList.add('review-flash');
            setTimeout(function () { best.classList.remove('review-flash'); }, 1200);
            return true;
        }
        return false;
    };
    // Split-mode follow. Navigation jumps (scrollToMdOffset) center + flash on
    // purpose; continuous synchronization instead aligns the matching rendered
    // run with the viewport BOTTOM and never animates.
    //
    // Both directions read one cached anchor table. Re-querying the DOM and
    // calling getBoundingClientRect per element ran on every frame of a scroll
    // gesture — with syntax highlighting that is a walk over every token span.
    // The table stores DOCUMENT-space geometry, so scrolling never stales it;
    // anything that can change layout drops it.
    var mdAnchorTable = null;
    function mdAnchors() {
        if (mdAnchorTable) return mdAnchorTable;
        var list = [];
        var scrollY = window.scrollY;
        document.querySelectorAll('[data-md-lo]').forEach(function (el) {
            var lo = parseInt(el.getAttribute('data-md-lo'), 10);
            if (isNaN(lo)) return;
            var rect = el.getBoundingClientRect();
            if (rect.width <= 0 && rect.height <= 0) return;  // not laid out
            list.push({ lo: lo, top: rect.top + scrollY, bottom: rect.bottom + scrollY });
        });
        list.sort(function (a, b) { return a.lo - b.lo; });
        // Keep the table monotonic in Y: an anchor can only ever be at or below
        // its predecessor, and the interpolation below relies on that.
        for (var i = 1; i < list.length; i++) {
            if (list[i].top < list[i - 1].top) list[i].top = list[i - 1].top;
        }
        mdAnchorTable = list;
        return list;
    }
    function invalidateMdAnchors() { mdAnchorTable = null; }
    window.addEventListener('resize', invalidateMdAnchors);
    window.addEventListener('load', invalidateMdAnchors);
    // Images and KaTeX resize blocks after first layout.
    document.addEventListener('load', invalidateMdAnchors, true);
    window.invalidateMdAnchors = invalidateMdAnchors;

    // Y (document space) for a FRACTIONAL markdown offset, by interpolating
    // between the two anchors around it. Both scales are monotonic, so the
    // result is monotonic: the follow can neither stall nor run backwards.
    //
    // Anchoring to a rendered LINE (an earlier cut) could do both, because a
    // source line and a rendered line are different objects — the two panes
    // wrap at different widths.
    function mdYForPosition(position) {
        var anchors = mdAnchors();
        if (!anchors.length) return null;
        var lo = 0, hi = anchors.length - 1;
        if (position <= anchors[0].lo) return anchors[0].top;
        if (position >= anchors[hi].lo) {
            var last = anchors[hi];
            return last.bottom > last.top ? last.bottom : last.top;
        }
        while (lo + 1 < hi) {                     // binary search: last anchor <= position
            var mid = (lo + hi) >> 1;
            if (anchors[mid].lo <= position) lo = mid; else hi = mid;
        }
        var a = anchors[lo], b = anchors[lo + 1];
        var span = b.lo - a.lo;
        if (span <= 0) return a.top;
        var t = Math.max(0, Math.min(1, (position - a.lo) / span));
        return a.top + (b.top - a.top) * t;
    }

    // The inverse: the fractional markdown offset at a document-space Y.
    function mdPositionForY(y) {
        var anchors = mdAnchors();
        if (!anchors.length) return null;
        if (y <= anchors[0].top) return anchors[0].lo;
        var last = anchors[anchors.length - 1];
        if (y >= last.top) return last.lo;
        var lo = 0, hi = anchors.length - 1;
        while (lo + 1 < hi) {
            var mid = (lo + hi) >> 1;
            if (anchors[mid].top <= y) lo = mid; else hi = mid;
        }
        var a = anchors[lo], b = anchors[lo + 1];
        var span = b.top - a.top;
        if (span <= 0) return b.lo;
        var t = Math.max(0, Math.min(1, (y - a.top) / span));
        return a.lo + (b.lo - a.lo) * t;
    }
    window.editMDCurrentScrollPosition = function () {
        return mdPositionForY(window.scrollY + 8);
    };

    // Set by any scroll the user drives, cleared by each fragment swap: a late
    // settle pass consults it before touching the viewport (see settlePreviewLayout).
    var userScrolledSinceSettle = false;

    // Programmatic scrolls must not be reported back as user scrolls; the flag
    // clears on the next frame, by which time WebKit has fired the event.
    var suppressScrollReport = 0;
    function beginScrollReportSuppression() {
        suppressScrollReport++;
    }
    function endScrollReportSuppressionAfterFrame() {
        requestAnimationFrame(function () {
            suppressScrollReport = Math.max(0, suppressScrollReport - 1);
        });
    }
    function programmaticScroll(y) {
        var maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
        beginScrollReportSuppression();
        window.scrollTo(0, Math.max(0, Math.min(y, maxY)));
        endScrollReportSuppressionAfterFrame();
    }
    window.programmaticScroll = programmaticScroll;

    // The editor reports the position at ITS TOP edge, so put the matching point
    // at ours. Aligning bottom edges instead pinned Preview to zero for the
    // whole first screenful (the target Y minus a viewport height is negative).
    // No easing: the position is already continuous, and smoothing only adds lag
    // behind the gesture.
    window.syncScrollToMdPosition = function (position) {
        var y = mdYForPosition(position);
        if (y === null) return false;
        programmaticScroll(y - 8);
        return true;
    };
    window.syncScrollToEdge = function (edge) {
        programmaticScroll(edge === 'top' ? 0 : document.documentElement.scrollHeight);
    };

    // PUSH the position on every frame of a user scroll. Polling it from Swift
    // per wheel event meant one round trip in flight at a time and the rest of
    // the gesture's frames dropped — the editor moved in visible jerks.
    var scrollReportQueued = false;
    function reportScroll() {
        var maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
        if (maxY <= 0.5) return;      // nothing to scroll — no position to share
        var payload;
        if (window.scrollY <= 0.5) {
            payload = { edge: 'top' };
        } else if (window.scrollY >= maxY - 0.5) {
            payload = { edge: 'bottom' };
        } else {
            var position = mdPositionForY(window.scrollY + 8);   // our TOP edge
            if (position === null) return;
            payload = { position: position };
        }
        try {
            window.webkit.messageHandlers.previewScroll.postMessage(payload);
        } catch (e) {}
    }
    window.addEventListener('scroll', function () {
        if (suppressScrollReport > 0) return;   // our own restore, not the user
        // The user has taken the viewport: a late settle pass (an image or the
        // KaTeX webfonts landing seconds after the edit) must not yank them back
        // to the anchor captured when the fragment was swapped in.
        userScrolledSinceSettle = true;
        if (scrollReportQueued) return;
        scrollReportQueued = true;
        requestAnimationFrame(function () {
            scrollReportQueued = false;
            reportScroll();
        });
    }, { passive: true });

    // D4: hover copy button on code blocks and blockquotes.
    function copyPreviewText(text, btn) {
        function ok() {
            var prev = btn.textContent;
            btn.textContent = '✓';
            setTimeout(function () { btn.textContent = prev; }, 1000);
        }
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(ok).catch(function () {
                fallbackPreviewCopy(text); ok();
            });
        } else {
            fallbackPreviewCopy(text); ok();
        }
    }
    function fallbackPreviewCopy(text) {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.left = '-9999px';
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); } catch (e) {}
        document.body.removeChild(ta);
    }
    function attachPreviewCopyButton(el) {
        if (el.querySelector('.copy-block-btn')) return;
        // One button per logical quote tree: a nested blockquote belongs
        // to its outer quote and is copied together with it.
        if (el.tagName === 'BLOCKQUOTE' && el.parentElement.closest('blockquote')) return;
        el.classList.add('copy-host');
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'copy-block-btn';
        btn.textContent = '⎘';
        btn.title = 'Copy';
        btn.onclick = function (e) {
            e.preventDefault();
            e.stopPropagation();
            var clone = el.cloneNode(true);
            clone.querySelectorAll('.copy-block-btn').forEach(function (b) { b.remove(); });
            copyPreviewText(clone.innerText || '', btn);
        };
        el.appendChild(btn);
    }
    function hydratePreviewCopyButtons() {
        document.querySelectorAll('pre, blockquote').forEach(attachPreviewCopyButton);
    }

    function hydratePreviewMath() {
        if (typeof katex === 'undefined') return;
        document.querySelectorAll('.math:not(.math-rendered)').forEach(function (el) {
            var tex = el.textContent;
            try {
                katex.render(tex, el, {
                    displayMode: el.classList.contains('math-display'),
                    throwOnError: false
                });
                el.classList.add('math-rendered');
                el.classList.remove('math-error');
            } catch (e) {
                el.classList.add('math-error');
                el.textContent = tex;
            }
        });
    }

    // ⌘F find (sprint 5). Highlighting is done by wrapping matched runs in
    // <span class="editmd-find"> — no source is touched, and clearing unwraps
    // and re-normalizes the text. Case-insensitive substring, matching the
    // default of Source/Visual's NSTextFinder. The Swift side drives every
    // search (including a re-run after a fragment swap), so this holds no state
    // that must survive innerHTML replacement beyond the last query string.
    var findMatches = [];
    var findCurrent = -1;
    function clearFindHighlights() {
        var root = document.getElementById('preview-content');
        var spans = root ? root.querySelectorAll('span.editmd-find') : [];
        spans.forEach(function (s) {
            var t = document.createTextNode(s.textContent);
            s.parentNode.replaceChild(t, s);
        });
        if (root && spans.length) root.normalize();
        findMatches = [];
        findCurrent = -1;
    }
    function collectFindTextNodes(root) {
        var nodes = [];
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: function (n) {
                if (!n.nodeValue) return NodeFilter.FILTER_REJECT;
                var p = n.parentElement;
                if (!p) return NodeFilter.FILTER_REJECT;
                var tag = p.tagName;
                if (tag === 'SCRIPT' || tag === 'STYLE') return NodeFilter.FILTER_REJECT;
                // The hover copy button's glyph is chrome, not content.
                if (p.classList && p.classList.contains('copy-block-btn')) {
                    return NodeFilter.FILTER_REJECT;
                }
                // KaTeX output duplicates every formula (visible HTML + hidden
                // MathML with the raw TeX annotation): matching inside it
                // double-counts, can select an invisible node, and wrapping
                // spans there breaks formula layout.
                if (p.closest && p.closest('.katex')) return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_ACCEPT;
            }
        });
        var n;
        while ((n = walker.nextNode())) nodes.push(n);
        return nodes;
    }
    // Split one text node around each match and wrap the hits. Matches never
    // cross a node boundary (an inline element between two words is a gap), the
    // same limitation the native find bar has on rendered rich text.
    // A case-insensitive regex over the ORIGINAL text keeps offsets exact —
    // indexing into the original with toLowerCase() offsets drifted on
    // characters whose lowercase form has a different length (Turkish İ).
    function highlightFindInNode(node, findRegex, out) {
        var text = node.nodeValue;
        findRegex.lastIndex = 0;
        var m = findRegex.exec(text);
        if (!m) return;
        var frag = document.createDocumentFragment();
        var last = 0;
        while (m) {
            if (m.index > last) frag.appendChild(document.createTextNode(text.slice(last, m.index)));
            var span = document.createElement('span');
            span.className = 'editmd-find';
            span.textContent = m[0];
            frag.appendChild(span);
            out.push(span);
            last = m.index + m[0].length;
            if (m[0].length === 0) { findRegex.lastIndex += 1; }
            m = findRegex.exec(text);
        }
        if (last < text.length) frag.appendChild(document.createTextNode(text.slice(last)));
        node.parentNode.replaceChild(frag, node);
    }
    function setFindCurrent(index) {
        if (findCurrent >= 0 && findCurrent < findMatches.length) {
            findMatches[findCurrent].classList.remove('editmd-find-current');
        }
        findCurrent = index;
        if (findCurrent >= 0 && findCurrent < findMatches.length) {
            var el = findMatches[findCurrent];
            el.classList.add('editmd-find-current');
            el.scrollIntoView({ block: 'center', inline: 'nearest' });
        }
    }
    // Returns {count, index} (index is 1-based, 0 = none). Keeps the current
    // ordinal when a re-run (after a content edit) still has that many matches.
    window.editMDFind = function (query) {
        var prevCurrent = findCurrent;
        clearFindHighlights();
        var q = query || '';
        if (!q) return { count: 0, index: 0 };
        var root = document.getElementById('preview-content');
        if (!root) return { count: 0, index: 0 };
        var escaped = q.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
        var findRegex = new RegExp(escaped, 'gi');
        var nodes = collectFindTextNodes(root);
        for (var i = 0; i < nodes.length; i++) {
            highlightFindInNode(nodes[i], findRegex, findMatches);
        }
        if (!findMatches.length) { findCurrent = -1; return { count: 0, index: 0 }; }
        var target = (prevCurrent >= 0 && prevCurrent < findMatches.length) ? prevCurrent : 0;
        setFindCurrent(target);
        return { count: findMatches.length, index: findCurrent + 1 };
    };
    window.editMDFindStep = function (delta) {
        if (!findMatches.length) return { count: 0, index: 0 };
        var n = findMatches.length;
        var next = ((findCurrent + delta) % n + n) % n;
        setFindCurrent(next);
        return { count: n, index: findCurrent + 1 };
    };
    window.editMDFindClear = function () {
        clearFindHighlights();
        return { count: 0, index: 0 };
    };

    // Make the DOM live again. Deliberately cheap: no geometry is read here,
    // because hydrate runs BEFORE the new content has been laid out. Everything
    // that depends on final geometry belongs in settlePreviewLayout.
    window.editMDHydratePreviewContent = function () {
        hydrateTaskCheckboxes();
        hydrateBuiltInPluginTokens();
        hydrateWikiLinks();
        hydrateLocalLinks();
        hydratePreviewCopyButtons();
        hydratePreviewMath();
        invalidateMdAnchors();
    };

    // One settle pass over final geometry: drop the anchor cache, re-place the
    // line-number gutter, and (optionally) restore the scroll anchor. Both the
    // gutter walk and the anchor table read getBoundingClientRect for every
    // tagged element, so this must run ONCE per layout — not once in hydrate
    // (pre-layout, therefore wrong) and again afterwards.
    function settlePreviewLayout(position, pixelY) {
        invalidateMdAnchors();
        alignLineNumberGutter();
        if (userScrolledSinceSettle) return;   // the user owns the viewport now
        if (position !== null && position !== undefined) {
            window.syncScrollToMdPosition(position);
        } else if (pixelY !== null && pixelY !== undefined) {
            programmaticScroll(pixelY);
        }
    }

    // Images and the KaTeX webfonts land after first layout and change block
    // heights, which moves every anchor below them. Replay the settle when they
    // do — on the first page load as well as after a fragment swap; before, only
    // the fragment path did this and a freshly opened math document kept a stale
    // anchor table (split-scroll sync drifted until the next resize).
    function replayPreviewSettle(root, position) {
        root.querySelectorAll('img').forEach(function (image) {
            if (image.complete) return;
            image.addEventListener('load', function () {
                settlePreviewLayout(position, null);
            }, { once: true });
        });
        // A resolved FontFaceSet promise would replay immediately on every edit
        // and defeat the pixel-stable first settle. Replay only while this DOM
        // actually has fonts still landing.
        if (document.fonts && document.fonts.status === 'loading') {
            document.fonts.ready.then(function () { settlePreviewLayout(position, null); });
        }
    }

    // SYNCHRONOUS on purpose. This function is the Swift side's continuation:
    // whatever it waits on, the render task waits on too. It used to await two
    // requestAnimationFrames "for layout" — and a WKWebView that is not
    // producing frames (occluded, off-screen, a suspended rendering update)
    // never fires them, so the promise never settled, the awaiting task never
    // released the render slot, and Preview froze on the first edit for the rest
    // of the session. Nothing here needs a frame: reading geometry in
    // settlePreviewLayout forces a synchronous layout, which is exactly the
    // "after layout" state we wanted. Late shifts (images, webfonts) are picked
    // up by replayPreviewSettle, which is fire-and-forget — if frames never
    // come, we lose a scroll-anchor touch-up, never the content update.
    window.editMDReplacePreview = function (payload) {
        if (!payload || payload.revision < window.editMDPreviewRevision) return false;
        var root = document.getElementById('preview-content');
        if (!root) return false;
        var position = payload.position;
        var pixelY = null;
        var replayPosition = position;
        if (position === null || position === undefined) {
            // Typing is a content update, not a scroll gesture. Preserve the
            // exact viewport instead of re-interpreting its old markdown offset
            // in the new DOM (which visibly nudged the first edit after a click).
            pixelY = window.scrollY;
            // Late image/font layout needs the semantic point that occupied the
            // viewport before the swap; replaying pixelY after heights change
            // would show different content.
            replayPosition = window.editMDCurrentScrollPosition();
        }
        // Replacing a long document with a shorter one can make WebKit clamp
        // scrollY before our explicit restore. That implicit scroll belongs to
        // this update transaction and must never be reported back to Source.
        beginScrollReportSuppression();
        try {
            root.innerHTML = payload.html;
            // The old find spans were just discarded with the previous DOM; drop
            // the stale references so a later step/clear can't touch dead nodes.
            // An active find is re-run from Swift right after this returns.
            findMatches = [];
            findCurrent = -1;
            window.editMDPreviewRevision = payload.revision;
            window.editMDHydratePreviewContent();
            userScrolledSinceSettle = false;
            settlePreviewLayout(position, pixelY);
            replayPreviewSettle(root, replayPosition);
            return true;
        } finally {
            endScrollReportSuppressionAfterFrame();
        }
    };

    window.editMDHydratePreviewContent();
    settlePreviewLayout(null, null);
    replayPreviewSettle(document.getElementById('preview-content'), null);
    </script>
    </body>
    </html>
    """
    return PreviewPageRender(html: html, hasMathAssets: mathAssets)
}
