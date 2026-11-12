#!/usr/bin/env python3
"""Builds the documentation section of the Porthole website from the app's own source, so it cannot drift from what the app says.

    python3 tools/build_docs.py [--site ~/Desktop/porthole-site-1.2.0] [--curated tools/docs_curated.json]

Reads (this repository's app/ and the engine's config catalogue):
  * every setting in the app's screens (SettingsGroup / *Row(id:, title:, info:, subtitle:) in app/Sources/UI)  -> docs/settings.html
  * every engine line (ConfigCatalog.generated.swift: key, kind, default, section, note)                       -> docs/engine-lines.html
  * the app's own messages (InstallCheck results, errorDescription texts, "failed" states, ErrorText)           -> docs/messages.html
  * tools/docs_curated.json: things written by hand (a log line and what it means, a symptom and the fix)       -> docs/errors.html
and writes docs/index.html (search), docs/docs-index.json (what the search reads), docs/docs.css and docs/docs.js.

It writes into the site folder only. It never commits or pushes anything. The text of the site's header and footer is taken from help.html, so it follows the site.
"""
import argparse, html, json, os, re, sys, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
APP = os.path.join(REPO, "app")

ap = argparse.ArgumentParser()
ap.add_argument("--site", default=os.path.expanduser("~/Desktop/porthole-site-1.2.0"))
ap.add_argument("--curated", default=os.path.join(HERE, "docs_curated.json"))
ap.add_argument("--catalog", default=os.path.join(REPO, "vendor", "Madeira", "app", "Madeira", "ConfigCatalog.generated.swift"))
ap.add_argument("--repo", help="a folder holding app/Sources and app/Runtime to read instead of this repository's (for example a git archive of a release tag)")
ap.add_argument("--emit-swift", help="also write the entries that can be recognised in a log (their \"log\" needles) as a Swift file for the app (app/Sources/Core/DocsDiagnosis.generated.swift)")
ap.add_argument("--emit-engine-lines", help="only write the app's own list of engine lines (key, title, default, short note) as Swift, from --catalog, and stop")
ap.add_argument("--public", action="store_true", help="leave out the hand-written entries marked \"since\" (they describe things a released build does not have)")
args = ap.parse_args()
if args.repo:
    APP = os.path.join(os.path.abspath(args.repo), "app")
SITE = os.path.abspath(args.site)
OUT = os.path.join(SITE, "docs")


# --------------------------------------------------------------------------- Swift helpers

def unesc(s):
    s = re.sub(r"\\u\{([0-9a-fA-F]+)\}", lambda m: chr(int(m.group(1), 16)), s)
    s = s.replace('\\"', '"').replace("\\'", "'").replace("\\n", " ").replace("\\t", " ").replace("\\\\", "\\")
    s = re.sub(r"\\\(([^()]|\([^()]*\))*\)", "\u2026", s)       # an interpolation becomes an ellipsis
    return re.sub(r"\s+", " ", s).strip()


def string_after(text, key):
    """The Swift string literal after `key:` (several joined with +), or None."""
    m = re.search(r"\b" + key + r":\s*\"", text)
    if not m:
        return None
    i = m.end()
    out = []
    while True:
        j = i
        while j < len(text):
            if text[j] == "\\":
                j += 2
                continue
            if text[j] == '"':
                break
            j += 1
        out.append(text[i:j])
        k = j + 1
        m2 = re.match(r"\s*\+\s*\"", text[k:])
        if m2:
            i = k + m2.end()
            continue
        break
    return unesc("".join(out))


def balanced(src, start, open_c="(", close_c=")"):
    depth = 0
    i = start
    instr = False
    while i < len(src):
        c = src[i]
        if instr:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                instr = False
        else:
            if c == '"':
                instr = True
            elif c == open_c:
                depth += 1
            elif c == close_c:
                depth -= 1
                if depth == 0:
                    return src[start:i + 1]
        i += 1
    return src[start:]


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def words(name):
    name = re.sub(r"(Page|Section|View|Screen|Sheet|Group|Panel)$", "", name)
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name).strip() or name


# --------------------------------------------------------------------------- settings

ROW = re.compile(r"\b([A-Z][A-Za-z]*Row)\(\s*id:\s*\"")
GROUP = re.compile(r"\bSettingsGroup\(\s*title:\s*\"")
STRUCT = re.compile(r"^\s*(?:private\s+|fileprivate\s+)?struct\s+(\w+)\s*:\s*[^{]*\bView\b", re.M)

AREAS = [  # (path fragment, area, order)
    ("UI/Settings/", "Settings", 0),
    ("UI/Game/", "A game's own page", 1),
    ("UI/InGame/", "The in-game menu", 2),
    ("UI/Reports", "Reports", 3),
    ("UI/Steam", "Steam", 4),
    ("UI/Stores", "Stores", 5),
    ("UI/Library/", "Library", 6),
]


def area_of(rel):
    for frag, name, order in AREAS:
        if frag in rel:
            return name, order
    if re.search(r"(Epic|Gog|Itch|Amazon|EA)LibraryScreens", rel):
        return "Stores", 5
    return "Other screens", 9


def parse_settings():
    root = os.path.join(APP, "Sources", "UI")
    entries = []
    for dp, _, fs in os.walk(root):
        for f in sorted(fs):
            if not f.endswith(".swift"):
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, os.path.join(APP, "Sources"))
            src = read(p)
            events = []
            for m in STRUCT.finditer(src):
                events.append((m.start(), "struct", m.group(1), None))
            for m in GROUP.finditer(src):
                t = balanced(src, m.start() + len("SettingsGroup"))
                events.append((m.start(), "group", string_after(t, "title"), string_after(t, "note")))
            for m in ROW.finditer(src):
                t = balanced(src, m.start() + len(m.group(1)))
                events.append((m.start(), "row", m.group(1), t))
            events.sort(key=lambda e: e[0])
            struct = None
            group = (None, None)
            for _, kind, a, b in events:
                if kind == "struct":
                    struct = a
                    group = (None, None)
                elif kind == "group":
                    group = (a, b)
                else:
                    title = string_after(b, "title")
                    info = string_after(b, "info")
                    sub = string_after(b, "subtitle")
                    rid = string_after(b, "id")
                    if not title or "\u2026" == title:
                        continue
                    if not (info or sub) and a in ("ValueRow", "SidebarRow", "StoreSignInRow"):
                        continue
                    area, order = area_of(rel)
                    entries.append(dict(area=area, order=order, page=words(struct or f[:-6]), group=group[0] or "", groupNote=group[1] or "",
                                        control=a[:-3], title=title, info=info or "", subtitle=sub or "", id=rid or "", file=rel))
    # the same row can appear twice (a page reused in two places): keep the first
    seen, out = set(), []
    for e in entries:
        k = (e["area"], e["page"], e["group"], e["title"], e["info"])
        if k in seen:
            continue
        seen.add(k)
        out.append(e)
    return out


# --------------------------------------------------------------------------- engine lines

def parse_catalog(path):
    src = read(path)
    out = []
    for m in re.finditer(r"ConfigOption\(key:\s*\"", src):
        t = balanced(src, m.start() + len("ConfigOption"))
        key = string_after(t, "key")
        kind = re.search(r"kind:\s*\.(\w+)", t)
        default = string_after(t, "defaultValue")
        cat = string_after(t, "category")
        note = string_after(t, "note")
        title = string_after(t, "title")
        ch = re.search(r"choices:\s*\[(.*?)\]\s*,\s*sources", t, re.S)
        choices = re.findall(r"\"((?:[^\"\\]|\\.)*)\"", ch.group(1)) if ch else []
        out.append(dict(key=key, kind=kind.group(1) if kind else "text", default=default or "", section=cat or "Other",
                        note=clean_note(note or ""), title=clean_note(title or ""), choices=[unesc(c) for c in choices]))
    return out


# --------------------------------------------------------------------------- messages

def parse_messages():
    out = []
    # install check results
    p = os.path.join(APP, "Sources", "Core", "InstallCheck.swift")
    src = read(p) if os.path.exists(p) else ""
    for m in re.finditer(r"\.init\(id:\s*\"", src):
        t = balanced(src, m.start() + len(".init"))
        title, detail, level = string_after(t, "title"), string_after(t, "detail"), re.search(r"level:\s*\.(\w+)", t)
        if title:
            out.append(dict(kind="Install check", title=title, text=detail or "", level=level.group(1) if level else ""))
    # errorDescription blocks and failed states, everywhere
    for sub in ("Sources", "Runtime"):
        for dp, _, fs in os.walk(os.path.join(APP, sub)):
            for f in sorted(fs):
                if not f.endswith(".swift"):
                    continue
                p = os.path.join(dp, f)
                src = read(p)
                for m in re.finditer(r"errorDescription\s*:\s*String\?\s*\{", src):
                    block = balanced(src, m.end() - 1, "{", "}")
                    for line in block.splitlines():
                        s = line.strip()
                        mm = re.match(r"(?:case\s+[^:]+:\s*)?(?:return\s+)?\"", s)
                        if mm and ('"' in s):
                            text = string_after("x: " + s[mm.end() - 1:], "x")
                            if text and len(text) > 25 and " " in text:
                                out.append(dict(kind="Error", title=text, text="", level=""))
                for m in re.finditer(r"\.failed\(\s*\"", src):
                    t = balanced(src, m.start() + len(".failed"))
                    text = string_after("x: " + t[1:-1], "x")
                    if text and len(text) > 25 and " " in text:
                        out.append(dict(kind="A game or download stopped", title=text, text="", level=""))
    # ErrorText: every sentence
    p = os.path.join(APP, "Sources", "Core", "ErrorText.swift")
    src = read(p) if os.path.exists(p) else ""
    for m in re.finditer(r"\"((?:[^\"\\]|\\.)*)\"", src):
        text = unesc(m.group(1))
        if len(text) > 40 and " " in text and not text.startswith("NS") and "Domain" not in text:
            out.append(dict(kind="Plain-language error", title=text, text="", level=""))
    seen, uniq = set(), []
    for e in out:
        k = e["title"]
        if k in seen:
            continue
        seen.add(k)
        uniq.append(e)
    return uniq


# --------------------------------------------------------------------------- html

def esc(s):
    return html.escape(s or "", quote=True)


def clean_note(s):
    """Engine notes carry the engine's internal revision tags (ml1040:). They mean nothing to a reader."""
    s = re.sub(r"\(\s*ml\d{3,4}[a-z]?\s*\)\s*", "", s)
    s = re.sub(r"\bml\d{3,4}[a-z]?\s*[:,]\s*", "", s)
    s = re.sub(r"\bml\d{3,4}[a-z]?\b", "", s)
    return re.sub(r"\s+", " ", s).strip()


def md(s):
    """Plain text with `code` spans."""
    return re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", re.sub(r"`([^`]+)`", r"<code>\1</code>", esc(s)))


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:80] or "x"


def template():
    src = read(os.path.join(SITE, "help.html"))
    head, rest = src.split('<main id="main">', 1)
    _, tail = rest.split("</main>", 1)
    head = head.replace(' aria-current="page"', "")
    return head, tail


def page(head, tail, title, description, path, body, extra_head=""):
    h = re.sub(r"<title>.*?</title>", "<title>%s</title>" % esc(title), head, flags=re.S)
    h = re.sub(r'(<meta name="description" content=")[^"]*"', lambda m: m.group(1) + esc(description) + '"', h)
    h = re.sub(r'(<meta property="og:description" content=")[^"]*"', lambda m: m.group(1) + esc(description) + '"', h)
    h = re.sub(r'(<meta property="og:title" content=")[^"]*"', lambda m: m.group(1) + esc(title) + '"', h)
    url = "https://portholehq.site" + path
    h = re.sub(r'(<link rel="canonical" href=")[^"]*"', lambda m: m.group(1) + url + '"', h)
    h = re.sub(r'(<meta property="og:url" content=")[^"]*"', lambda m: m.group(1) + url + '"', h)
    h = h.replace("</head>", '<link rel="stylesheet" href="/docs/docs.css?v=%s">\n%s</head>' % (VERSION, extra_head))
    t = tail.replace("</body>", '<script src="/docs/docs.js?v=%s" defer></script>\n</body>' % VERSION)
    return h + '<main id="main">\n' + body + "\n</main>" + t


NAV = [("index.html", "Search"), ("settings.html", "Settings"), ("engine-lines.html", "Engine lines"), ("errors.html", "Errors and log lines"), ("messages.html", "Messages")]


def subnav(current):
    items = []
    for f, label in NAV:
        cur = ' aria-current="page"' if f == current else ""
        href = "/docs/" if f == "index.html" else "/docs/" + f
        items.append('<a href="%s"%s>%s</a>' % (href, cur, esc(label)))
    return '<nav class="d-nav" aria-label="Documentation">%s</nav>' % "".join(items)


def filterbox(label, ph):
    return ('<input class="search" type="search" data-docs-filter placeholder="%s" aria-label="%s" autocomplete="off">\n'
            '<p class="fine" data-docs-count aria-live="polite" style="margin:8px 0 0"></p>' % (esc(ph), esc(label)))


def kind_label(k):
    return {"bool": "On/off", "int": "Number", "choice": "One of a list", "text": "Text"}.get(k, k)


def example_for(e):
    k = e["key"]
    if k.startswith("env."):
        return "%s = %s" % (k, "1" if e["kind"] == "bool" else (e["default"] or "value") if e["kind"] != "choice" else (e["choices"][0] if e["choices"] else "value"))
    if e["kind"] == "bool":
        return "%s = 1" % k
    if e["kind"] == "int":
        return "%s = %s" % (k, e["default"] if re.fullmatch(r"-?\d+", e["default"] or "") else "1")
    if e["kind"] == "choice" and e["choices"]:
        return "%s = %s" % (k, e["choices"][0])
    return "%s = value" % k


# --------------------------------------------------------------------------- build

VERSION = datetime.datetime.utcnow().strftime("%Y%m%d%H%M")


def emit_engine_lines():
    lines = parse_catalog(args.catalog)
    out = ["// Generated by tools/build_docs.py from the engine's option list. Do not edit by hand.", "// What the engine-lines editor shows under what was typed (EngineLineHelp).", "",
           "enum EngineLineCatalog {", "    struct Info { let title: String; let defaultValue: String; let note: String }", "    static let byKey: [String: Info] = ["]
    for e in sorted(lines, key=lambda x: x["key"]):
        note = e["note"] if len(e["note"]) <= 240 else e["note"][:239].rstrip() + "\u2026"
        out.append("        %s: Info(title: %s, defaultValue: %s, note: %s)," % (json.dumps(e["key"], ensure_ascii=False), json.dumps(e["title"], ensure_ascii=False),
                                                                           json.dumps(e["default"], ensure_ascii=False), json.dumps(note, ensure_ascii=False)))
    out += ["    ]", "}", ""]
    open(args.emit_engine_lines, "w", encoding="utf-8").write("\n".join(out))
    print("engine lines for the app: %d" % len(lines))


def build():
    if args.emit_engine_lines:
        return emit_engine_lines()
    os.makedirs(OUT, exist_ok=True)
    head, tail = template()
    index = []   # for the search: t = type, n = name, s = secondary line, x = text, u = url

    # ---- settings
    settings = parse_settings()
    areas = {}
    for s in settings:
        areas.setdefault((s["order"], s["area"]), {}).setdefault(s["page"], {}).setdefault(s["group"], []).append(s)
    body = ['<div class="wrap page doc docs">', '<p class="eyebrow">Documentation</p>', "<h1>Every setting in Porthole</h1>", subnav("settings.html"),
            '<p class="lede">What each switch, slider and button in the app does, in the order the app shows them. Search for a word from its name, or from what you want to change.</p>',
            filterbox("Filter the settings", "Filter: swap, controller, power, drive...")]
    toc = ['<ul class="d-toc">']
    sections = []
    for (order, area) in sorted(areas):
        aid = slug(area)
        toc.append('<li><a href="#%s">%s</a></li>' % (aid, esc(area)))
        sec = ['<section class="d-section" id="%s"><h2>%s</h2>' % (aid, esc(area))]
        for pg in areas[(order, area)]:
            pid = slug(area + "-" + pg)
            sec.append('<div class="d-block" id="%s"><h3>%s</h3>' % (pid, esc(pg)))
            for gname, rows in areas[(order, area)][pg].items():
                if gname:
                    sec.append('<h4>%s</h4>' % esc(gname))
                    if rows[0]["groupNote"]:
                        sec.append('<p class="d-note">%s</p>' % esc(rows[0]["groupNote"]))
                for r in rows:
                    rid = slug("%s-%s-%s" % (pg, gname, r["title"]))
                    desc = r["info"] or r["subtitle"]
                    text = " ".join([area, pg, gname, r["title"], desc])
                    sec.append('<article class="d-entry" id="%s" data-q="%s"><h5>%s <span class="tag">%s</span></h5>%s</article>'
                               % (rid, esc(text.lower()), esc(r["title"]), esc(r["control"]), ("<p>%s</p>" % esc(desc)) if desc else '<p class="fine">No further description in the app.</p>'))
                    index.append(dict(t="Setting", n=r["title"], s="%s \u203A %s%s" % (area, pg, (" \u203A " + gname) if gname else ""), x=desc[:400], u="/docs/settings.html#" + rid))
            sec.append("</div>")
        sec.append("</section>")
        sections.append("\n".join(sec))
    toc.append("</ul>")
    body += toc + sections + ["</div>"]
    open(os.path.join(OUT, "settings.html"), "w", encoding="utf-8").write(
        page(head, tail, "Every setting in Porthole | Documentation", "What each setting in Porthole does: appearance, performance, controls, Steam, storage, a game's own page and the in-game menu. Searchable.", "/docs/settings.html", "\n".join(body)))

    # ---- engine lines
    lines = parse_catalog(args.catalog)
    bysec = {}
    for e in lines:
        bysec.setdefault(e["section"], []).append(e)
    body = ['<div class="wrap page doc docs">', '<p class="eyebrow">Documentation</p>', "<h1>Engine lines</h1>", subnav("engine-lines.html"),
            '<p class="lede">Engine lines change how the Windows layer underneath Porthole behaves, for example <code>swap-coverage = wide</code> or <code>env.MADEIRA_FEX_AVX = 1</code>. '
            "There are %d of them. Most games need none." % len(lines) + "</p>",
            '<section class="tool"><h2>How to use one</h2><ol class="d-steps"><li>Open the game in Porthole and go to its settings.</li><li>Under <b>Starting</b>, tap <b>This game\u2019s engine lines</b>.</li>'
            "<li>Type the line, one per line, in the form <code>key = value</code>, then start the game again.</li></ol>"
            '<p class="fine">A line there applies to that game only and wins over the app-wide <code>madeira.cfg</code>. A line that starts with <code>env.</code> sets an environment variable for the game. '
            "These are for finding and working around problems; a wrong value can stop a game from starting. Remove the line to undo it.</p></section>",
            filterbox("Filter the engine lines", "Filter: swap, avx, d3d12, vram, mouse...")]
    toc = ['<ul class="d-toc">']
    sections = []
    for sec in sorted(bysec, key=lambda s: (-len(bysec[s]), s)):
        sid = slug(sec)
        toc.append('<li><a href="#%s">%s <span class="fine">%d</span></a></li>' % (sid, esc(sec), len(bysec[sec])))
        part = ['<section class="d-section" id="%s"><h2>%s</h2>' % (sid, esc(sec))]
        for e in sorted(bysec[sec], key=lambda x: x["key"]):
            eid = slug(e["key"])
            meta = ["Type: %s" % kind_label(e["kind"])]
            if e["default"]:
                meta.append("Default: <code>%s</code>" % esc(e["default"]))
            if e["choices"]:
                meta.append("Choices: " + ", ".join("<code>%s</code>" % esc(c) for c in e["choices"][:12]))
            text = " ".join([e["key"], e["title"], e["note"], sec])
            part.append('<article class="d-entry" id="%s" data-q="%s"><h5><code>%s</code> <span class="tag">%s</span></h5>%s%s<p class="d-meta">%s</p><pre class="d-ex">%s</pre></article>'
                        % (eid, esc(text.lower()), esc(e["key"]), esc(kind_label(e["kind"])),
                           ("<p class=\"d-title\">%s</p>" % esc(e["title"])) if e["title"] else "",
                           ("<p>%s</p>" % md(e["note"])) if e["note"] else '<p class="fine">No description written yet.</p>',
                           " \u00B7 ".join(meta), esc(example_for(e))))
            index.append(dict(t="Engine line", n=e["key"], s=sec + ((" \u00B7 " + e["title"]) if e["title"] else ""), x=e["note"][:400], u="/docs/engine-lines.html#" + eid))
        part.append("</section>")
        sections.append("\n".join(part))
    toc.append("</ul>")
    body += toc + sections + ["</div>"]
    open(os.path.join(OUT, "engine-lines.html"), "w", encoding="utf-8").write(
        page(head, tail, "Engine lines (madeira.cfg) | Porthole documentation", "Every engine line Porthole understands: what it does, its default, its type and an example. Searchable.", "/docs/engine-lines.html", "\n".join(body)))

    # ---- messages
    msgs = parse_messages()
    bykind = {}
    for m in msgs:
        bykind.setdefault(m["kind"], []).append(m)
    order = ["Install check", "A game or download stopped", "Error", "Plain-language error"]
    body = ['<div class="wrap page doc docs">', '<p class="eyebrow">Documentation</p>', "<h1>What Porthole says</h1>", subnav("messages.html"),
            '<p class="lede">The messages Porthole shows when something is wrong, copied from the app so you can find the one in front of you. A \u2026 stands for a name or number that changes.</p>',
            filterbox("Filter the messages", "Paste or type part of the message...")]
    for kind in sorted(bykind, key=lambda k: order.index(k) if k in order else 99):
        body.append('<section class="d-section" id="%s"><h2>%s</h2>' % (slug(kind), esc(kind)))
        for m in bykind[kind]:
            mid = slug(m["title"])[:60]
            text = (m["title"] + " " + m["text"]).lower()
            body.append('<article class="d-entry" id="%s" data-q="%s"><h5>%s</h5>%s</article>' % (mid, esc(text), esc(m["title"]), ("<p>%s</p>" % esc(m["text"])) if m["text"] else ""))
            index.append(dict(t="Message", n=m["title"][:140], s=kind, x=m["text"][:300], u="/docs/messages.html#" + mid))
        body.append("</section>")
    body.append("</div>")
    open(os.path.join(OUT, "messages.html"), "w", encoding="utf-8").write(
        page(head, tail, "What Porthole says: messages and errors | Documentation", "The messages and errors Porthole shows, with their exact wording, so you can search for the one you see.", "/docs/messages.html", "\n".join(body)))

    # ---- curated errors and log lines
    curated = json.load(open(args.curated, encoding="utf-8")) if os.path.exists(args.curated) else []
    if args.public:
        curated = [c for c in curated if not c.get("since")]
    groups = {}
    for c in curated:
        groups.setdefault(c["group"], []).append(c)
    body = ['<div class="wrap page doc docs">', '<p class="eyebrow">Documentation</p>', "<h1>Errors and log lines</h1>", subnav("errors.html"),
            '<p class="lede">Something stopped, or a report\u2019s log shows a line you do not understand. Search for the words in the message. Each entry says what it means, what to try, and how sure we are.</p>',
            filterbox("Filter the errors", "Filter: black screen, pairing, 12_0, fence, memory...")]
    for g in groups:
        body.append('<section class="d-section" id="%s"><h2>%s</h2>' % (slug(g), esc(g)))
        for c in groups[g]:
            cid = slug(c["id"])
            fixes = "".join("<li>%s</li>" % md(f) for f in c.get("try", []))
            sure = c.get("sure", "")
            text = " ".join([c["title"], c.get("sees", ""), c.get("meaning", ""), " ".join(c.get("try", [])), g])
            body.append('<article class="d-entry" id="%s" data-q="%s"><h5>%s</h5>%s%s%s%s</article>' % (
                cid, esc(text.lower()), esc(c["title"]),
                ('<p class="d-see"><b>You see:</b> <code>%s</code></p>' % esc(c["sees"])) if c.get("sees") else "",
                ("<p>%s</p>" % md(c["meaning"])) if c.get("meaning") else "",
                ('<p class="d-tryh"><b>Try:</b></p><ul>%s</ul>' % fixes) if fixes else "",
                ('<p class="fine">%s</p>' % esc(sure)) if sure else ""))
            index.append(dict(t="Error", n=c["title"], s=g, x=((c.get("sees", "") + " " + c.get("meaning", "")).strip())[:400], u="/docs/errors.html#" + cid))
        body.append("</section>")
    body.append("</div>")
    open(os.path.join(OUT, "errors.html"), "w", encoding="utf-8").write(
        page(head, tail, "Errors and log lines | Porthole documentation", "What an error or a line in Porthole's log means and what to try: black screens, pairing, memory, feature levels, downloads.", "/docs/errors.html", "\n".join(body)))

    # ---- the front page with the big search
    counts = dict(settings=len(settings), lines=len(lines), errors=len(curated), messages=len(msgs))
    body = ['<div class="wrap page doc docs">', '<p class="eyebrow">Documentation</p>', "<h1>Search the Porthole documentation</h1>", subnav("index.html"),
            '<p class="lede">Type an error message, a setting, an engine line or a word like <i>black screen</i>. Everything on this site\u2019s documentation is searched at once.</p>',
            '<input class="search big" type="search" id="docs-search" placeholder="Search: a message you saw, swap, write-buffer-immediate, controller..." aria-label="Search the documentation" autocomplete="off" autofocus>',
            '<p class="fine" id="docs-status" aria-live="polite" style="margin:8px 0 0"></p>', '<div id="docs-results" class="d-results"></div>',
            '<div class="d-cards" id="docs-cards">',
            '<a class="d-card" href="/docs/errors.html"><b>Errors and log lines</b><span>%d entries: a message or a line in a log, what it means, what to try.</span></a>' % counts["errors"],
            '<a class="d-card" href="/docs/settings.html"><b>Settings</b><span>%d settings, as the app shows them.</span></a>' % counts["settings"],
            '<a class="d-card" href="/docs/engine-lines.html"><b>Engine lines</b><span>%d lines for <code>madeira.cfg</code> and a game\u2019s own engine lines.</span></a>' % counts["lines"],
            '<a class="d-card" href="/docs/messages.html"><b>What Porthole says</b><span>%d messages copied from the app.</span></a>' % counts["messages"],
            "</div>",
            '<p class="fine" style="margin-top:28px">Not here? The <a href="/help.html">Help page</a> has short answers, and the <a href="https://discord.gg/N7PkdptTFn">Discord</a> has people. '
            'These pages are built from the app itself, so a setting that was added after your version may be listed.</p>', "</div>"]
    open(os.path.join(OUT, "index.html"), "w", encoding="utf-8").write(
        page(head, tail, "Documentation: search errors, settings and engine lines | Porthole", "Search Porthole's documentation: error messages, every setting, every engine line.", "/docs/", "\n".join(body)))

    import shutil
    for a in ("docs.css", "docs.js"):
        shutil.copyfile(os.path.join(HERE, "docs_assets", a), os.path.join(OUT, a))
    if args.emit_swift:
        rows = [c for c in curated if c.get("log")]
        swift_lines = ["// Generated by tools/build_docs.py from tools/docs_curated.json. Do not edit by hand.", "// The documentation's entries that a run's log can point to (DocsDiagnosis).", "",
                 "extension DocsDiagnosis {", "    static let entries: [Entry] = ["]
        for c in rows:
            swift_lines.append("        Entry(id: %s, short: %s, needles: [%s])," % (json.dumps(c["id"], ensure_ascii=False), json.dumps(c.get("short", c["title"]), ensure_ascii=False),
                                                                                  ", ".join(json.dumps(n, ensure_ascii=False) for n in c["log"])))
        swift_lines += ["    ]", "}", ""]
        open(args.emit_swift, "w", encoding="utf-8").write("\n".join(swift_lines))
        titles = sorted({x["title"] for x in settings if x["title"]})
        out2 = os.path.join(os.path.dirname(args.emit_swift), "DocsSettings.generated.swift")
        open(out2, "w", encoding="utf-8").write("\n".join(
            ["// Generated by tools/build_docs.py. Do not edit by hand.", "// The titles of the settings the website's documentation describes (DocsLink.documented).", "",
             "extension DocsLink {", "    static let documentedSettings: Set<String> = ["] + ["        %s," % json.dumps(t, ensure_ascii=False) for t in titles] + ["    ]",
             "    /// The engine lines the website describes.", "    static let documentedEngineLines: Set<String> = ["] + ["        %s," % json.dumps(e["key"], ensure_ascii=False) for e in sorted(lines, key=lambda x: x["key"])] + ["    ]", "}", ""]))
    json.dump(index, open(os.path.join(OUT, "docs-index.json"), "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    print("settings %d, engine lines %d, messages %d, curated %d, index entries %d" % (len(settings), len(lines), len(msgs), len(curated), len(index)))


build()
