#!/usr/bin/env bash
# t-4a1b: static-site guard. The pages under site/ must load the shared stylesheet and script, carry no
# placeholder links, and link only to files and anchors that exist. Run alone: bash tests/site.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${SITE_DIR:-$ROOT/site}"
PAGES="${SITE_PAGES:-index.html compare.html learnings.html}"

python3 - "$ROOT" "$SITE" "$PAGES" <<'PY'
import os, re, sys
from html.parser import HTMLParser

root, site, pages = sys.argv[1], sys.argv[2], sys.argv[3].split()
REPO = re.compile(r'^https://github\.com/sunitghub/canon-skills/(?:blob|tree)/main/([^#?]*)')
MAX_ASSET = 300 * 1024
errors = []

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids, self.srcs = [], set(), []
        self.styles = self.inline_scripts = 0
        self.has_css = self.has_js = False
        self.title, self._in_title, self._in_script = '', False, False
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if 'id' in a: self.ids.add(a['id'])
        if tag == 'a' and 'href' in a: self.links.append(a['href'])
        if tag in ('img', 'source') and 'src' in a: self.srcs.append(a['src'])
        if tag == 'style': self.styles += 1
        if tag == 'link' and a.get('rel') == 'stylesheet' and a.get('href') == 'style.css': self.has_css = True
        if tag == 'script':
            if a.get('src') == 'site.js': self.has_js = True
            elif 'src' not in a: self.inline_scripts += 1
        if tag == 'title': self._in_title = True
    def handle_endtag(self, tag):
        if tag == 'title': self._in_title = False
    def handle_data(self, data):
        if self._in_title: self.title += data

parsed = {}
for name in pages:
    path = os.path.join(site, name)
    if not os.path.isfile(path):
        errors.append(f'{name}: page is missing')
        continue
    text = open(path, encoding='utf-8').read()
    p = Page(); p.feed(text); parsed[name] = p
    if not p.has_css: errors.append(f'{name}: does not load style.css')
    if not p.has_js: errors.append(f'{name}: does not load site.js')
    if p.styles: errors.append(f'{name}: has {p.styles} inline <style> block(s)')
    if p.inline_scripts: errors.append(f'{name}: has {p.inline_scripts} inline <script> block(s)')
    if 'MOCKUP' in text: errors.append(f'{name}: still contains MOCKUP')
    if p.title.strip().lower().endswith('mockup'): errors.append(f'{name}: title ends in Mockup')
    if 'href="#"' in text: errors.append(f'{name}: has a placeholder href="#"')

css = os.path.join(site, 'style.css')
if not os.path.isfile(css): errors.append('style.css is missing')
elif '[hidden]' not in open(css, encoding='utf-8').read(): errors.append('style.css lacks the [hidden] rule')
if not os.path.isfile(os.path.join(site, 'site.js')): errors.append('site.js is missing')

referenced = set()
for name, p in parsed.items():
    for href in p.links:
        if href.startswith(('mailto:', 'tel:', 'data:')): continue
        m = REPO.match(href)
        if m:
            target = m.group(1).rstrip('/')
            if target and not os.path.exists(os.path.join(root, target)):
                errors.append(f'{name}: repo link points at a path that does not exist: {target}')
            continue
        if re.match(r'^[a-z][a-z0-9+.-]*:', href): continue  # other external links
        base, _, frag = href.partition('#')
        if base:
            dest = os.path.normpath(os.path.join(site, base.split('?')[0]))
            if not os.path.isfile(dest):
                errors.append(f'{name}: link target does not exist: {href}')
                continue
            ids = parsed.get(os.path.basename(dest))
            if frag and ids is not None and frag not in ids.ids:
                errors.append(f'{name}: anchor not found in {base}: #{frag}')
        elif frag and frag not in p.ids:
            errors.append(f'{name}: anchor not found on the page: #{frag}')
    for src in p.srcs:
        if re.match(r'^[a-z][a-z0-9+.-]*:', src): continue
        dest = os.path.normpath(os.path.join(site, src))
        if not os.path.isfile(dest): errors.append(f'{name}: image does not exist: {src}')
        else: referenced.add(os.path.relpath(dest, site))

assets = os.path.join(site, 'assets')
if os.path.isdir(assets):
    for f in sorted(os.listdir(assets)):
        rel = os.path.join('assets', f)
        if rel not in referenced: errors.append(f'{rel}: orphan asset, no page uses it')
        if os.path.getsize(os.path.join(assets, f)) > MAX_ASSET: errors.append(f'{rel}: larger than 300 KB')

if errors:
    print('site check FAILED:')
    for e in errors: print('  - ' + e)
    sys.exit(1)
print(f'site check ok: {len(parsed)} pages')
PY
