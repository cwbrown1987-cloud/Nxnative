#!/usr/bin/env python3
"""The DM_* environment switches the code reads, as one table: docs/env_switches.tsv.

Columns: name; class; meaning; since (the commit that introduced it, for a reviewer to check the meaning against); read in; documented in.
The last two are taken from the sources each time; class, meaning and since are kept by hand and carried over when the table is written again
(dm/tools/env_switch_draft.py gathers what the code comments, the history and the docs say about a switch).
  env_switches.py           write the table: a new switch gets a row with a guessed class and no meaning
  env_switches.py --check   exit 1 when the table is not the one the sources give (a switch read but not listed, a row for one read nowhere) or a row has no meaning
Classes: player (a launcher setting, dm/games/settings.tsv), path (names a file or folder), switch (changes what the host does: a feature, a mode, a profile key's
override), diagnostic (logs, dumps, probes, measurements), test (read only by tests)."""
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
TABLE = REPO / 'docs/env_switches.tsv'
HEAD = ('# DM_* environment switches the code reads. Written by dm/tools/env_switches.py: "read in" and "documented in" come from the sources; class, meaning and since are\n'
        '# kept by hand. class: player = a launcher setting (dm/games/settings.tsv), path = names a file or folder, switch = changes what the host does, diagnostic = logs, dumps,\n'
        '# probes and measurements, test = read only by tests. since: the commit that introduced the switch. A new getenv("DM_...") needs a row here with its meaning\n'
        '# (dm/tools/tests/test_env_switches.py); dm/tools/env_switch_draft.py <name> gathers what the code, the history and the docs say about it.\n'
        'name\tclass\tmeaning\tsince\tread in\tdocumented in\n')
CLASSES = ('player', 'path', 'switch', 'diagnostic', 'test')
CODE = ('.c', '.m', '.h', '.inc', '.swift', '.py', '.sh', '.S')
NAME = r'DM_[A-Z0-9_]*[A-Z0-9]'


def tracked():
    out = subprocess.run(['git', 'ls-files', 'dm', 'scripts', 'docs', 'README.md'], cwd=REPO, capture_output=True, text=True, check=True).stdout.split('\n')
    return [p for p in out if p and 'third_party' not in p.split('/')]


def defined_macros(text):   # names the code defines as preprocessor macros (the generated profile header's DM_GAME_*, host constants), which are not environment switches
    return set(re.findall(r'#\s*define\s+(' + NAME + r')', text))


def scan():
    reads, docs, macros = {}, {}, set()
    for p in tracked():
        path = REPO / p
        if not path.is_file(): continue
        text = path.read_text(errors='replace')
        if p.endswith('.md'):
            for n in set(re.findall(r'`(' + NAME + r')', text)): docs.setdefault(n, set()).add(p)
            continue
        if not p.endswith(CODE) and not p.startswith('scripts/'): continue
        macros |= defined_macros(text)
        if '/tests/' in p:   # a test's own switches only (getenv / os.environ); the names in its fixtures are data
            found = re.findall(r'(?:getenv\(|environ(?:\.get\(|\[))\s*["\'](' + NAME + r')["\']', text)
        elif p.endswith('.sh'): found = re.findall(r'\$\{?(' + NAME + r')\b', text) + re.findall(r'["\'](' + NAME + r')["\']', text)
        else: found = re.findall(r'["\'](' + NAME + r')=?["\']', text)
        for n in set(found): reads.setdefault(n, set()).add(p)
    for n in macros: reads.pop(n, None); docs.pop(n, None)
    return reads, docs


def guess(name, files, player):   # a new row's class, for whoever writes its meaning to correct
    if name in player: return 'player'
    if all('/tests/' in f for f in files): return 'test'
    if re.search(r'_(DIR|PATH|FILE|ROOT)$', name): return 'path'
    return 'diagnostic'


def rows():
    """(table text, rows without a meaning or with an unknown class, names documented but read nowhere)"""
    reads, docs = scan()
    player = {l.split('\t')[0] for l in (REPO / 'dm/games/settings.tsv').read_text().split('\n') if l.startswith('DM_')}
    kept = {}
    if TABLE.exists():
        for l in TABLE.read_text().split('\n'):
            f = l.split('\t')
            if len(f) == 6 and f[0].startswith('DM_'): kept[f[0]] = f[1:4]
    out, bad = [], []
    for n in sorted(reads):
        cls, meaning, since = kept.get(n, [guess(n, reads[n], player), '', ''])
        if cls not in CLASSES or not meaning.strip(): bad.append(n)
        out.append(f'{n}\t{cls}\t{meaning}\t{since}\t{" ".join(sorted(reads[n]))}\t{" ".join(sorted(docs.get(n, ()))) or "-"}\n')
    unread = sorted(n for n in docs if n not in reads and not n.endswith('_'))
    return HEAD + ''.join(out), bad, unread


if __name__ == '__main__':
    text, bad, unread = rows()
    if sys.argv[1:] == ['--check']:
        problems = []
        if not TABLE.exists() or TABLE.read_text() != text: problems.append('docs/env_switches.tsv is not current: run dm/tools/env_switches.py')
        if bad: problems.append('switches without a meaning or a class (one of ' + ', '.join(CLASSES) + '): ' + ' '.join(bad))
        print('\n'.join(problems))
        sys.exit(1 if problems else 0)
    TABLE.write_text(text)
    print(f'{TABLE.relative_to(REPO)}: {text.count(chr(10)) - HEAD.count(chr(10))} switches, {len(bad)} without a meaning')
    if unread: print('documented but read nowhere: ' + ' '.join(unread))
