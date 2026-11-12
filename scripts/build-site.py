"""Render the bilingual changelogs using only Python's standard library."""
from pathlib import Path
from html import escape
import re

root = Path(__file__).resolve().parent.parent

def inline(text):
    text = escape(text)
    text = re.sub(r'`([^`]+)`', r'<code>\1</code>', text)
    return re.sub(r'\[([^\]]+)\]\((https://[^\s)]+)\)', r'<a href="\2">\1</a>', text)

def render(text):
    parts, listing = [], False
    for line in text.splitlines():
        if not line.startswith('- ') and listing:
            parts.append('</ul>'); listing = False
        if line.startswith('# '):
            continue
        if line.startswith('## '):
            title = line[3:].replace('[Unreleased]', 'Unreleased' if text.startswith('# Changelog') else '未发布')
            parts.append('<h2>' + inline(title) + '</h2>')
        elif line.startswith('### '):
            parts.append('<h3>' + inline(line[4:]) + '</h3>')
        elif line.startswith('- '):
            if not listing: parts.append('<ul>'); listing = True
            parts.append('<li>' + inline(line[2:]) + '</li>')
        elif line.strip(): parts.append('<p>' + inline(line) + '</p>')
    if listing: parts.append('</ul>')
    return '\n'.join(parts)

sources = [root/'CHANGELOG.md', root/'CHANGELOG.zh-CN.md']
versions = [re.findall(r'^## \[([^\]]+)\]', p.read_text(), re.M) for p in sources]
assert versions[0] == versions[1], 'English and Chinese changelog versions must match'
for lang, source, home, output, title in [('en', sources[0], 'index.html', 'changelog.html', 'Changelog'), ('zh-CN', sources[1], 'zh.html', 'changelog-zh.html', '更新日志')]:
    page = (root/'website'/home).read_text()
    head, rest = page.split('<main>', 1)
    footer = rest.split('</main>', 1)[1]
    head = re.sub(r'<title>.*?</title>', f'<title>{title} — SpeekCoding</title>', head)
    head = head.replace('href="#"', f'href="{home}"').replace('href="#workflow"', f'href="{home}#workflow"').replace('href="#details"', f'href="{home}#details"')
    head = head.replace('href="index.html" lang=', 'href="changelog.html" lang=').replace('href="zh.html" lang=', 'href="changelog-zh.html" lang=')
    back = '← Back to product' if lang == 'en' else '← 返回产品介绍'
    body = f'<main class="changelog"><a class="text-link" href="{home}">{back}</a><h1>{title}</h1>{render(source.read_text())}</main>'
    (root/'website'/output).write_text(head + body + footer)
