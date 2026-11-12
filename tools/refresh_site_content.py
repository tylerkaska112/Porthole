#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 The Porthole authors. See LICENSE.
"""Keeps the parts of the Porthole website that follow the app up to date, from this repository's CHANGELOG.json:

  * changelog.html   the "Every build" list (the newest builds, each with what was added, changed and fixed)
  * download.html    the "Latest release" line (only when --release VERSION BUILD is given: the page names the public release, not the newest build)
  * sitemap.xml      each page's <lastmod>, from the date the page file was last changed

    python3 tools/refresh_site_content.py [--site ~/Desktop/porthole-site] [--builds 25]

It only edits files in the site folder (between marker comments, so the hand-written text around them is never touched) and publishes nothing: commit and push
the site yourself. Running it twice in a row changes nothing the second time.
"""
import argparse, datetime, html, json, os, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("--site", default=os.path.expanduser("~/Desktop/porthole-site"))
ap.add_argument("--builds", type=int, default=25)
ap.add_argument("--only-builds", metavar="N,N,...", help="list only these build numbers (the public releases), newest first: private test builds never appear on the site")
ap.add_argument("--max-build", type=int, help="list only builds up to this number, newest first by build number: the public release and what came before it (later private test builds stay off the site)")
ap.add_argument("--release", nargs=2, metavar=("VERSION", "BUILD"), help="the newest PUBLIC release, for the download page's line (leave out to leave that line alone)")
args = ap.parse_args()
site = os.path.expanduser(args.site)
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

entries = json.load(open(os.path.join(root, "CHANGELOG.json"), encoding="utf-8"))
if not entries:
    sys.exit("CHANGELOG.json is empty")
if args.only_builds:
    wanted = {int(n) for n in args.only_builds.split(",") if n.strip()}
    entries = sorted((x for x in entries if int(x["build"]) in wanted), key=lambda x: int(x["build"]), reverse=True)
    missing = wanted - {int(x["build"]) for x in entries}
    if missing:
        sys.exit(f"CHANGELOG.json has no entry for build(s) {sorted(missing)}")
elif args.max_build:
    entries = sorted((x for x in entries if int(x["build"]) <= args.max_build), key=lambda x: int(x["build"]), reverse=True)
    if not entries:
        sys.exit(f"no build up to {args.max_build} in CHANGELOG.json")
newest = entries[0]
e = html.escape


def read(name):
    return open(os.path.join(site, name), encoding="utf-8").read()


def write(name, text):
    path = os.path.join(site, name)
    if os.path.exists(path) and open(path, encoding="utf-8").read() == text:
        return False
    open(path, "w", encoding="utf-8").write(text)
    return True


def between(text, start, end, inner, fallback_anchor=None):
    """Replace what is between two marker comments; add the markers before `fallback_anchor` the first time."""
    block = f"<!-- {start} -->{inner}<!-- {end} -->"
    pattern = re.compile(r"<!-- %s -->.*?<!-- %s -->" % (re.escape(start), re.escape(end)), re.S)
    if pattern.search(text):
        return pattern.sub(lambda m: block, text, count=1)
    if fallback_anchor and fallback_anchor in text:
        return text.replace(fallback_anchor, block + "\n" + fallback_anchor, 1)
    sys.exit(f"no marker <!-- {start} --> and no place to add it")


def listing(title, items):
    if not items:
        return ""
    return f"<p><b>{e(title)}</b></p><ul>" + "".join(f"<li>{e(i)}</li>" for i in items) + "</ul>"


# 1. changelog.html: every build
rows = []
for entry in entries[: args.builds]:
    body = listing("Added", entry.get("added", [])) + listing("Changed", entry.get("changed", [])) + listing("Fixed", entry.get("fixed", []))
    summary = entry.get("summary", "")
    rows.append(f'<details><summary>{e(entry["version"])} (build {e(str(entry["build"]))}): {e(summary)}</summary><div class="a">{body or "<p>No details.</p>"}</div></details>')
if args.only_builds:
    heading = ('Every release, newest first', f'Every public release, as the app lists them in Settings &#8250; Updates. Test builds made between releases are not listed here.')
else:
    heading = ('Every build, newest first', f'The last {len(rows)} builds, exactly as the app lists them in Settings &#8250; Updates. This list is made from the project\'s change log.')
builds = (f'\n  <h2 id="builds">{heading[0]}</h2>\n  <p class="fine">{heading[1]}</p>\n'
          f'  <div class="faq">\n    ' + "\n    ".join(rows) + "\n  </div>\n  ")
page = read("changelog.html")
page = between(page, "builds:start", "builds:end", builds, fallback_anchor='<p class="fine" style="margin-top:30px">Every release is also on the project')
changed = [("changelog.html", write("changelog.html", page))]

# 2. download.html: the newest public release (the newest build in the change log may not have been released)
today = datetime.date.today()
if args.release:
    line = f'Latest release: {e(args.release[0])} (build {e(args.release[1])}). Page updated {today.day} {today.strftime("%B %Y")}.'
    dl = read("download.html")
    new_dl = between(dl, "build:start", "build:end", line)
    # the date only moves when the release does (or the page file was edited), so a second run is a no-op
    old = re.search(r"<!-- build:start -->(.*?)<!-- build:end -->", dl, re.S)
    if old and re.sub(r"Page updated .*", "", old.group(1)) == re.sub(r"Page updated .*", "", line):
        new_dl = dl
    changed.append(("download.html", write("download.html", new_dl)))
    # the structured data search engines read names the same version
    for page in ("index.html", "download.html"):
        text = read(page)
        updated = re.sub(r'("softwareVersion":\s*")[^"]*(")', lambda m: m.group(1) + args.release[0] + m.group(2), text)
        changed.append((page + " (structured data)", write(page, updated)))

# 3. sitemap.xml: lastmod from each page file
sm = read("sitemap.xml")


def lastmod(match):
    path = match.group(1)
    name = "index.html" if path in ("", "/") else path.lstrip("/")
    file = os.path.join(site, name)
    date = datetime.date.fromtimestamp(os.path.getmtime(file)) if os.path.exists(file) else today
    return f"<loc>https://portholehq.site{path}</loc><lastmod>{date.isoformat()}</lastmod>"


sm_new = re.sub(r"<loc>https://portholehq\.site([^<]*)</loc><lastmod>[^<]*</lastmod>", lastmod, sm)
changed.append(("sitemap.xml", write("sitemap.xml", sm_new)))

for name, did in changed:
    print(("updated " if did else "unchanged ") + name)
print(f"newest build {newest['version']} ({newest['build']}), {len(rows)} builds listed")
