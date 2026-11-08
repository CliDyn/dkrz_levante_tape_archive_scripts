#!/usr/bin/env python3
"""Plan tar balls for an AWI-ESM3 experiment folder (archive.sh --mode awiesm3).

Each output variable gets its own tar balls, so it can be retrieved without
the rest. A variable is split into chunks of whole years (1, 2, 5, 10, 20, 25,
50 or 100, aligned to the calendar) that stay below --max-gb; if the whole run
fits, it is one tar ball. Variables smaller than --min-gb are bundled per
component and output stream. Each restart date is one tar ball with all
components. log/, config/ and the rest of the folder go into logs_config.

Sizes are what lands on tape: compression is measured on a sample of each
variable, and a tar ball is compressed with zstd only if that pays off.

Writes <plan>/<tar>.lst (one absolute path per line) and <plan>/tars.tsv
(tar name, compression, files, bytes, estimated bytes on tape).
"""

import argparse
import os
import re
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait

ENC = dict(encoding='utf-8', errors='surrogateescape')
GB = 1e9
ROUND_YEARS = [1, 2, 5, 10, 20, 25, 50, 100]
SAMPLE = 32 << 20
ZSTD_WORTH = 1.2

# Not archived at all (paths relative to the experiment folder)
EXCLUDE = re.compile(r'^(input|outdata/fesom/regridded|outdata/fesom_damaged_links'
                     r'|run_[^/]+/(input|bin))$')
# run_*/work holds copies of output, restarts and of the logs in log/. Only
# small logs that exist nowhere else are kept; the NODE, debug.root.01/02,
# ifs.stat and XIOS logs are not.
WORK_KEEP = re.compile(r'^(debug\.root\.0[3-9]|debug\.notroot\..*|.*\.log|.*\.clock|meminfo\.txt'
                       r'|LPJ-GUESS_.*\.txt|.*\.env|hostlist|hostfile_srun)$')
WORK_KEEP_MAX = 200e6

# Output file names; the year must be read from these, not guessed
OIFS = re.compile(r'^(?P<var>.+)_(?P<y>\d{4,})-\d{4,}\.nc$')
FESOM = re.compile(r'^(?P<var>.+?)\.fesom(?P<gr>\.gr)?\.(?P<y>\d{4,})\.nc$')
LPJG_PERIOD = re.compile(r'^(?P<y>\d{4,})\d{4}-\d{8,}$')
OTHER_OUT = [OIFS, re.compile(r'^(?P<var>.+)[._](?P<y>\d{4,})\.nc$')]

# Restart folders, with the offset from the year in the name to the model
# year the restart ends (lpjg_state_1852 is written at the end of 1851)
RESTART = [
    (re.compile(r'^fesom/fesom\.(?P<y>\d{4,})\.(oce|ice)\.restart/'), 0),
    (re.compile(r'^oifs/(?P<y>\d{4,})1231/'), 0),
    (re.compile(r'^lpj_guess/lpjg_state_(?P<y>\d{4,})/'), -1),
    (re.compile(r'^oasis3mct/[^/]+_\d{8,}-(?P<y>\d{4,})1231$'), 0),
]


class File:
    __slots__ = ('path', 'size', 'link')

    def __init__(self, path, size, link):
        self.path, self.size, self.link = path, size, link


def list_dir(path, work):
    """Files and subfolders of one folder, without sizes. In run_*/work only the
    kept logs are taken and subfolders are not entered."""
    files, dirs, skipped = [], [], 0
    with os.scandir(path) as it:
        for e in it:
            if e.is_dir(follow_symlinks=False):
                if work:
                    skipped += 1
                else:
                    dirs.append(e.path)
            elif work and not WORK_KEEP.match(e.name):
                skipped += 1
            else:
                files.append(File(e.path, 0, e.is_symlink()))
    return files, dirs, skipped


def set_size(f):
    f.size = os.lstat(f.path).st_size


def scan(pool, top):
    """Return all files below top, the excluded folders and the number of run_*/work entries left out.

    A stat of a large file on Lustre asks the storage servers for its size and
    is slow, so sizes are taken in parallel after the listing.
    """
    files, excluded, work_skipped = [], [], 0
    pending = {pool.submit(list_dir, top, False)}
    while pending:
        finished, pending = wait(pending, return_when=FIRST_COMPLETED)
        for fut in finished:
            found, dirs, skipped = fut.result()
            files.extend(found)
            work_skipped += skipped
            for d in dirs:
                rel = os.path.relpath(d, top)
                parts = rel.split('/')
                if EXCLUDE.match(rel):
                    excluded.append(rel)
                else:
                    work = len(parts) == 2 and parts[0].startswith('run_') and parts[1] == 'work'
                    pending.add(pool.submit(list_dir, d, work))
    list(pool.map(set_size, files, chunksize=64))
    kept = []
    for f in files:
        parts = os.path.relpath(f.path, top).split('/')
        if len(parts) == 3 and parts[0].startswith('run_') and parts[1] == 'work' and f.size > WORK_KEEP_MAX:
            work_skipped += 1
        else:
            kept.append(f)
    return kept, excluded, work_skipped


def zstd_sample(zstd, f):
    """Bytes read and bytes after zstd -3 for a sample from the middle of a file."""
    n = min(SAMPLE, f.size)
    with open(f.path, 'rb') as fh:
        fh.seek((f.size - n) // 2)
        data = fh.read(n)
    out = subprocess.run([zstd, '-3', '-q', '-c'], input=data, stdout=subprocess.PIPE, check=True).stdout
    return len(data), len(out)


def measure(pool, zstd, groups, per_group=1):
    """Compression ratio per group, sampled from its largest regular files."""
    jobs = []
    for key, files in groups.items():
        regular = sorted((f for f in files if not f.link and f.size >= 4096), key=lambda f: -f.size)
        jobs.extend((key, f) for f in regular[:per_group])
    sums = defaultdict(lambda: [0, 0])
    for (key, _), (raw, packed) in zip(jobs, pool.map(lambda j: zstd_sample(zstd, j[1]), jobs)):
        sums[key][0] += raw
        sums[key][1] += packed
    return {k: sums[k][0] / sums[k][1] if k in sums and sums[k][1] else 1.0 for k in groups}


class Tar:
    def __init__(self, name, files, ratio, note=''):
        self.name, self.files, self.note = name, files, note
        self.raw = sum(f.size for f in files)
        self.compress = 'zstd' if ratio >= ZSTD_WORTH else 'none'
        self.tape = self.raw / ratio if self.compress == 'zstd' else self.raw


def split_years(per_year, lo, hi):
    """Chunks of whole years (lists of years) for one variable."""
    years = sorted(per_year)
    if sum(per_year.values()) <= hi:
        return [years]
    for k in reversed(ROUND_YEARS):
        chunks = defaultdict(list)
        for y in years:
            chunks[y // k].append(y)
        chunks = [chunks[c] for c in sorted(chunks)]
        if k == 1 or all(sum(per_year[y] for y in c) <= hi for c in chunks):
            break
    # A short last chunk joins the one before it if that stays below the maximum
    if len(chunks) > 1:
        last = sum(per_year[y] for y in chunks[-1])
        prev = sum(per_year[y] for y in chunks[-2])
        if last < lo and last + prev <= hi:
            chunks[-2] += chunks.pop()
    return chunks


def fill(items, lo, hi):
    """Greedy bundles of (size, payload) items up to hi; a short last one joins the previous."""
    bundles, cur, size = [], [], 0.0
    for s, item in items:
        if cur and size + s > hi:
            bundles.append((size, cur))
            cur, size = [], 0.0
        cur.append(item)
        size += s
    if cur:
        if bundles and size < lo and bundles[-1][0] + size <= hi:
            bundles[-1] = (bundles[-1][0] + size, bundles[-1][1] + cur)
        else:
            bundles.append((size, cur))
    return [b for _, b in bundles]


def numbered(name, i, n):
    return name if n == 1 else '%s_%d' % (name, i + 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('source')
    parser.add_argument('plan')
    parser.add_argument('--min-gb', type=float, default=10)
    parser.add_argument('--max-gb', type=float, default=300)
    parser.add_argument('--zstd', default='zstd')
    parser.add_argument('--jobs', type=int, default=32)
    args = parser.parse_args()
    lo, hi = args.min_gb * GB, args.max_gb * GB
    top = os.path.abspath(args.source)

    pool = ThreadPoolExecutor(args.jobs)
    files, excluded, work_skipped = scan(pool, top)

    # Classify every file
    output = defaultdict(list)       # (component, variable) -> files
    output_year = {}                 # path -> year
    restarts = defaultdict(list)     # (year, component) -> files
    restart_common = []
    logs = []
    unmatched = defaultdict(list)    # folder -> files
    for f in files:
        rel = os.path.relpath(f.path, top)
        parts = rel.split('/')
        if parts[0] == 'outdata' and len(parts) >= 3:
            comp, name = parts[1], parts[-1]
            m = None
            if comp == 'oifs' and len(parts) == 3:
                m = OIFS.match(name)
                var = m and m.group('var')
            elif comp == 'fesom' and len(parts) == 3:
                m = FESOM.match(name)
                var = m and m.group('var') + ('_gr' if m.group('gr') else '')
            elif comp == 'lpj_guess' and len(parts) >= 4:
                m = LPJG_PERIOD.match(parts[2])
                sub = parts[3:]
                if sub[0] == 'run1':
                    sub = sub[1:]
                var = m and re.sub(r'\.out$', '', '_'.join(sub))
            elif len(parts) == 3:
                m = next((p.match(name) for p in OTHER_OUT if p.match(name)), None)
                var = m and m.group('var')
            if m:
                output[(comp, var)].append(f)
                output_year[f.path] = int(m.group('y'))
            else:
                unmatched['/'.join(parts[:2])].append(f)
        elif parts[0] == 'restart' and len(parts) >= 3:
            sub = '/'.join(parts[1:])
            for pattern, offset in RESTART:
                m = pattern.match(sub)
                if m:
                    restarts[(int(m.group('y')) + offset, parts[1])].append(f)
                    break
            else:
                restart_common.append(f)
        else:
            logs.append(f)

    tars = []

    # Output: one variable per tar ball, whole years, or bundled if small
    ratio = measure(pool, args.zstd, output)
    small = defaultdict(list)
    for (comp, var), fs in sorted(output.items()):
        r = ratio[(comp, var)]
        tape = sum(f.size for f in fs) / (r if r >= ZSTD_WORTH else 1.0)
        if tape < lo:
            stream = '_'.join(var.split('_')[:2]) if comp == 'oifs' else 'small'
            small[(comp, stream)].append((tape, (var, fs, r)))
            continue
        per_year = defaultdict(float)
        by_year = defaultdict(list)
        for f in fs:
            y = output_year[f.path]
            per_year[y] += f.size / (r if r >= ZSTD_WORTH else 1.0)
            by_year[y].append(f)
        for chunk in split_years(per_year, lo, hi):
            members = [f for y in chunk for f in by_year[y]]
            tars.append(Tar('%s/%s_%d-%d.tar' % (comp, var, chunk[0], chunk[-1]), members, r))
    for (comp, stream), items in sorted(small.items()):
        bundles = fill(sorted(items, key=lambda x: x[1][0]), lo, hi)
        for i, bundle in enumerate(bundles):
            members = [f for _, fs, _ in bundle for f in fs]
            raw = sum(f.size for f in members)
            tape = sum(sum(f.size for f in fs) / (r if r >= ZSTD_WORTH else 1.0) for _, fs, r in bundle)
            years = [output_year[f.path] for f in members]
            name = '%s/%s_bundle_%d-%d.tar' % (comp, numbered(stream, i, len(bundles)), min(years), max(years))
            tars.append(Tar(name, members, raw / tape if tape else 1.0,
                            '%d variables: %s' % (len(bundle), ' '.join(v for v, _, _ in bundle))))

    # Restarts: one tar ball per date with every component
    comp_files = defaultdict(list)
    for (year, comp), fs in restarts.items():
        comp_files[comp].extend(fs)
    comp_ratio = measure(pool, args.zstd, comp_files)
    for year in sorted(set(y for y, _ in restarts)):
        members, tape = [], 0.0
        for comp in sorted(comp_files):
            fs = restarts.get((year, comp), [])
            members.extend(fs)
            tape += sum(f.size for f in fs) / comp_ratio[comp]
        raw = sum(f.size for f in members)
        comps = sorted(c for (y, c) in restarts if y == year)
        tars.append(Tar('restart/restart_%d1231.tar' % year, members, raw / tape if tape else 1.0,
                        ' '.join(comps)))
    if restart_common:
        r = measure(pool, args.zstd, {'c': restart_common}, 5)['c']
        tars.append(Tar('restart/restart_common.tar', restart_common, r,
                        'restart files without a date (grids, weights, links)'))

    # Logs, config and everything else that is not output or restart
    for folder, fs in sorted(unmatched.items()):
        r = measure(pool, args.zstd, {'u': fs}, 5)['u']
        bundles = fill([(f.size / r, f) for f in sorted(fs, key=lambda f: f.path)], lo, hi)
        for i, b in enumerate(bundles):
            tars.append(Tar('other/%s.tar' % numbered(folder.replace('/', '_'), i, len(bundles)), b, r,
                            'no known name pattern in ' + folder))
    if logs:
        r = measure(pool, args.zstd, {'l': logs}, 10)['l']
        bundles = fill([(f.size / r, f) for f in sorted(logs, key=lambda f: f.path)], lo, hi)
        for i, b in enumerate(bundles):
            tars.append(Tar(numbered('logs_config', i, len(bundles)) + '.tar', b, r))

    names = [t.name for t in tars]
    if len(set(names)) != len(names):
        sys.exit('ERROR: duplicate tar ball names')

    # Write the plan
    for t in tars:
        lst = os.path.join(args.plan, t.name + '.lst')
        os.makedirs(os.path.dirname(lst), exist_ok=True)
        with open(lst, 'w', **ENC) as out:
            for f in sorted(t.files, key=lambda f: f.path):
                out.write(f.path + '\n')
    with open(os.path.join(args.plan, 'tars.tsv'), 'w', **ENC) as out:
        for t in tars:
            out.write('%s\t%s\t%d\t%d\t%d\t%s\n' % (t.name, t.compress, len(t.files), t.raw, t.tape, t.note))

    # Report
    def kind(t):
        return t.name.split('/')[0] if '/' in t.name else t.name.split('_')[0]
    print('Source: %s' % top)
    print('Tar balls %d-%d GB on tape (estimate), compressed with zstd where it shrinks them %.1fx or more'
          % (args.min_gb, args.max_gb, ZSTD_WORTH))
    print('')
    print('%-14s %6s %9s %9s %8s %8s %6s' % ('', 'tars', 'raw GB', 'tape GB', 'min GB', 'max GB', 'zstd'))
    stats = defaultdict(list)
    for t in tars:
        stats[kind(t)].append(t)
    for k, ts in sorted(stats.items()):
        print('%-14s %6d %9.0f %9.0f %8.1f %8.1f %6d' % (
            k, len(ts), sum(t.raw for t in ts) / GB, sum(t.tape for t in ts) / GB,
            min(t.tape for t in ts) / GB, max(t.tape for t in ts) / GB,
            sum(t.compress == 'zstd' for t in ts)))
    print('%-14s %6d %9.0f %9.0f' % ('total', len(tars), sum(t.raw for t in tars) / GB,
                                     sum(t.tape for t in tars) / GB))
    print('')
    print('Not archived:')
    folders = defaultdict(int)
    for d in excluded:
        folders[re.sub(r'^run_[^/]+/', 'run_*/', d)] += 1
    for d, n in sorted(folders.items()):
        print('  %s/%s' % (d, ' (%d folders)' % n if n > 1 else ''))
    print('  run_*/work: %d files and folders - copies of output, restarts and of the logs in log/'
          % work_skipped)
    if unmatched:
        print('')
        print('No known name pattern, packed by folder into other/:')
        for folder, fs in sorted(unmatched.items()):
            print('  %s: %d files, %.1f GB, e.g. %s' % (folder, len(fs), sum(f.size for f in fs) / GB,
                                                     os.path.basename(fs[0].path)))
    big = [t for t in tars if t.tape > hi]
    if big:
        print('')
        print('Above %d GB (a single year or file is larger):' % args.max_gb)
        for t in big:
            print('  %s %.0f GB' % (t.name, t.tape / GB))
    print('')
    print('Tar balls (estimated GB on tape, files, compression):')
    for t in tars:
        print('  %-60s %7.1f %7d  %s%s' % (t.name, t.tape / GB, len(t.files), t.compress,
                                          '  ' + t.note[:80] if t.note else ''))


if __name__ == '__main__':
    main()
