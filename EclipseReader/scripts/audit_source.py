"""Audit saved ordinary HTTP responses with the integration's exact observed selectors.
This is a portable fixture/markup audit, not execution of the Swift adapter.
"""
from pathlib import Path
from html.parser import HTMLParser
import hashlib
import json
import re
import sys
from urllib.parse import urlparse

class PageAudit(HTMLParser):
    def __init__(self):
        super().__init__(); self.images = []; self.chapters = []; self.row = None; self.cell = None
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'img' and 'pages__img' in a.get('class', '').split():
            self.images.append(a)
        if tag == 'tr': self.row = {'cells': [], 'links': []}
        if tag == 'td' and self.row is not None: self.cell = ''
        if tag == 'a' and self.row is not None: self.row['links'].append(a.get('href', ''))
    def handle_data(self, data):
        if self.cell is not None: self.cell += data
    def handle_endtag(self, tag):
        if tag == 'td' and self.row is not None and self.cell is not None:
            self.row['cells'].append(' '.join(self.cell.split())); self.cell = None
        if tag == 'tr' and self.row is not None:
            if self.row['cells'] and re.fullmatch(r'Berserk\s+Chapter\s+([A-P]0|\d+(?:\.\d+)?)', self.row['cells'][0], re.I):
                self.chapters.append(self.row)
            self.row = None

def audit(index: Path, chapter: Path):
    catalog = PageAudit(); catalog.feed(index.read_text(encoding='utf-8-sig'))
    reader = PageAudit(); reader.feed(chapter.read_text(encoding='utf-8-sig'))
    assert catalog.chapters, 'No real chapter rows found'
    assert len(reader.images) == 25, 'Observed chapter 384 had 25 pages'
    assert all(urlparse(i['src']).hostname == 'cdn.readberserk.com' for i in reader.images)
    assert [Path(urlparse(i['src']).path).name for i in reader.images] == [f'{i}.jpeg' for i in range(1, 26)]
    assert [i.get('loading') for i in reader.images[:4]] == ['eager', 'eager', 'eager', 'lazy']
    assert catalog.chapters[-1]['cells'][0] == 'Berserk Chapter A0'
    assert catalog.chapters[0]['cells'][0] == 'Berserk Chapter 386'
    report = {
        'date': '2026-11-20', 'method': 'Saved HTTP 200 HTML responses; portable HTMLParser audit',
        'swift_adapter_executed': False,
        'catalog_chapters': len(catalog.chapters),
        'first_story_chapter': catalog.chapters[-1]['cells'][0],
        'last_story_chapter': catalog.chapters[0]['cells'][0],
        'chapter_384_pages': len(reader.images),
        'image_host': 'cdn.readberserk.com',
        'page_loading': 'first three eager, subsequent pages lazy',
        'response_hashes': {'index': hashlib.sha256(index.read_bytes()).hexdigest(),
                            'chapter384': hashlib.sha256(chapter.read_bytes()).hexdigest()},
        'ios_build': 'not run', 'simulator_tests': 'not run', 'physical_device_tests': 'not run'
    }
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    audit(Path(sys.argv[1]), Path(sys.argv[2]))
