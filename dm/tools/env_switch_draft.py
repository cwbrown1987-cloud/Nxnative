#!/usr/bin/env python3
"""Draft material for the meanings in docs/env_switches.tsv: for each DM_* switch the code reads, what the sources and the history say about it.
For a reviewer writing or checking a row; it writes nothing into the repository.
  env_switch_draft.py [--rev upstream/main] [NAME ...]   one block per switch (all of them without names)
Each block has:
- the comment on each line that reads the switch, or the comment lines just above it;
- the commit that introduced it, with its subject and the paragraph of its body that names the switch;
- for a switch no longer read, the commit that removed it;
- the lines of the docs and game notes that mention it.
The commits come from one pass over the history (git log -p), cached in .git/env_switch_draft.json per revision."""
from pathlib import Path
import json
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'dm/tools'))
import env_switches   # noqa: E402

NAME = env_switches.NAME


def git(*a):
    return subprocess.run(['git', *a], cwd=REPO, capture_output=True, text=True, check=True).stdout


def history(rev):
    """{name: [first commit that added a line quoting it, last commit that removed one]} over the code of rev's history, cached by rev's hash"""
    head = git('rev-parse', rev).strip()
    cache = Path(git('rev-parse', '--git-common-dir').strip())
    cache = (cache if cache.is_absolute() else REPO / cache) / 'env_switch_draft.json'
    try:
        c = json.loads(cache.read_text())
        if c.get('head') == head: return c['names']
    except (OSError, ValueError): pass
    log = subprocess.run(['git', 'log', '--reverse', '-p', '--no-renames', '--format=@@C %H', head, '--', 'dm', 'scripts', ':!dm/third_party', ':!*.md', ':!*.tsv'],
                         cwd=REPO, capture_output=True, text=True, check=True).stdout
    names, commit = {}, None
    for line in log.split('\n'):
        if line.startswith('@@C '): commit = line[4:]; continue
        if not line or line[0] not in '+-' or line.startswith(('+++', '---')): continue
        for n in set(re.findall(r'["\'](' + NAME + r')=?["\']', line)):
            e = names.setdefault(n, [None, None])
            if line[0] == '+' and not e[0]: e[0] = commit
            if line[0] == '-': e[1] = commit
    # a name the pass above did not see quoted (a shell script reads it as $DM_X): the oldest and newest commits whose diffs add or remove it (git log -S)
    for n in env_switches.scan()[0]:
        if n in names: continue
        hits = git('log', '--reverse', '--format=%H', '-S' + n, head, '--', 'dm', 'scripts', ':!dm/third_party', ':!*.md', ':!*.tsv').split()
        if hits: names[n] = [hits[0], hits[-1]]
    cache.write_text(json.dumps({'head': head, 'names': names}))
    return names


def paragraph(commit, name):   # the commit's subject and the paragraph of its body (or the subject line itself) that names the switch
    body = git('show', '-s', '--format=%B', commit)
    subject = body.split('\n', 1)[0]
    for p in re.split(r'\n\s*\n', body):
        if name in p: return subject, ' '.join(p.split())
    return subject, ''


def comments(name, files):
    """per file: the line that reads the switch, and the comments in that file that name it (on the line or above it; the first three)"""
    out = []
    for f in files:
        lines = (REPO / f).read_text(errors='replace').split('\n')
        read = [i for i, l in enumerate(lines) if re.search(r'["\']' + re.escape(name) + r'=?["\']', l)]
        if not read: continue
        out.append(f'{f}:{read[0] + 1}: {lines[read[0]].strip()[:300]}')
        said = []
        for i, l in enumerate(lines):
            c = re.search(r'(?:^\s*|\s)(?://|#)\s*(.*)$', l)
            if c and name in c.group(1): said.append(f'{f}:{i + 1}: // {c.group(1).strip()[:300]}')
        out += said[:3]
    return out


def doc_lines(name):
    out = []
    for p in env_switches.tracked():
        if not p.endswith('.md'): continue
        for i, l in enumerate((REPO / p).read_text(errors='replace').split('\n'), 1):
            if '`' + name in l: out.append(f'{p}:{i}: {l.strip()[:400]}')
    return out


def main(argv):
    rev = 'upstream/main'
    if argv[:1] == ['--rev']: rev, argv = argv[1], argv[2:]
    reads, _ = env_switches.scan()
    hist = history(rev)
    for n in argv or sorted(reads):
        first, last = hist.get(n, [None, None])
        print(f'## {n}')
        print('read in: ' + (' '.join(sorted(reads.get(n, ()))) or 'nothing (removed)'))
        for c in comments(n, sorted(reads.get(n, ()))): print('comment: ' + c)
        if first:
            s, p = paragraph(first, n); print(f'introduced: {first[:8]} {s}'); p and print('  ' + p[:900])
        if n not in reads and last:
            s, p = paragraph(last, n); print(f'removed: {last[:8]} {s}'); p and print('  ' + p[:900])
        for d in doc_lines(n)[:6]: print('doc: ' + d)
        print()


if __name__ == '__main__':
    main(sys.argv[1:])
