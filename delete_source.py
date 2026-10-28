#!/usr/bin/env python3
"""Delete source files that archive.sh has packed, uploaded and verified.

Called through the delete_source.sh that archive.sh writes to its state
directory once every tar ball passed the packing, md5 and compare checks.

Dry run by default; pass --yes to delete. A file is only removed if its type,
size and mtime still match what was packed. Directories left empty afterwards
are removed too. Files that were never packed are listed and kept.

Lustre metadata calls are slow one at a time, so stat, directory listing and
unlink run in parallel threads (--jobs).
"""

import argparse
import json
import os
import stat
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

ENC = dict(encoding='utf-8', errors='surrogateescape')


def die(msg):
    print('ERROR: ' + msg)
    sys.exit(1)


def read_config(state):
    cfg = {}
    with open(os.path.join(state, 'config'), **ENC) as f:
        for line in f:
            key, _, value = line.rstrip('\n').partition('\t')
            cfg[key] = value
    return cfg


def atlas_ls(path):
    """Return the JSON listing of an archive path."""
    out = subprocess.run(['atlas', 'ls', '-l', '--format', 'json', path],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         universal_newlines=True)
    if out.returncode != 0:
        die('atlas ls %s failed: %s' % (path, out.stdout.strip()))
    return json.loads(out.stdout)


def archive_flags(dest, names):
    """Return the ScoutAM flags (e.g. 'ao--v') of the named files in dest.

    One listing of dest covers all files. Each atlas process starts dozens of
    threads, so running one per file in parallel hits the login node's limit.
    """
    listing = atlas_ls(dest + '/')
    if not listing.get('summary', {}).get('has_more'):
        flags = {e['name']: e.get('flags', '') for e in listing.get('entries', [])}
        return [flags.get(n, '') for n in names]
    result = []
    for n in names:
        entries = atlas_ls(dest + '/' + n).get('entries', [])
        result.append(entries[0].get('flags', '') if entries else '')
    return result


def show(title, paths, limit=20):
    print('%s: %d' % (title, len(paths)))
    for p in paths[:limit]:
        print('    ' + p)
    if len(paths) > limit:
        print('    ... (%d more)' % (len(paths) - limit))


def check_entry(entry):
    """Classify one manifest entry as 'delete', 'changed' or 'gone'."""
    kind, size, mtime, path = entry
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return 'gone', path, 0
    now_kind = 'l' if stat.S_ISLNK(st.st_mode) else 'f' if stat.S_ISREG(st.st_mode) else 'o'
    if (now_kind, st.st_size, st.st_mtime_ns) == (kind, int(size), int(mtime)):
        return 'delete', path, st.st_size
    return 'changed', path, 0


def list_dir(path):
    """Return the non-directory entries and subdirectories of one directory."""
    files, dirs = [], []
    with os.scandir(path) as it:
        for e in it:
            if e.is_dir(follow_symlinks=False):
                dirs.append(e.path)
            else:
                files.append(e.path)
    return files, dirs


def walk_parallel(pool, top):
    """Return all non-directory paths and all directories below top."""
    files, dirs = [], []
    pending = [pool.submit(list_dir, top)]
    while pending:
        f, d = pending.pop().result()
        files.extend(f)
        dirs.extend(d)
        pending.extend(pool.submit(list_dir, p) for p in d)
    return files, dirs


def unlink(path):
    try:
        os.unlink(path)
        return None
    except OSError as e:
        return '%s: %s' % (path, e)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('state', help='state directory written by archive.sh')
    parser.add_argument('--yes', action='store_true', help='actually delete')
    parser.add_argument('--no-tape-check', action='store_true',
                        help='do not require the tar balls to be written to tape')
    parser.add_argument('--jobs', type=int, default=32,
                        help='parallel metadata operations (default 32)')
    args = parser.parse_args()

    state = os.path.abspath(args.state)
    cfg = read_config(state)
    source, dest, name = cfg['SOURCE'], cfg['DEST'], cfg['NAME']
    ext = '.zst' if cfg.get('COMPRESS') == 'zstd' else ''
    print('Source:  ' + source)
    print('Archive: ' + dest)

    if not os.path.exists(os.path.join(state, 'ALL_OK')):
        die('archive.sh did not finish with all checks passed (no ALL_OK in %s)' % state)

    plan = os.path.join(state, 'plan')
    tars = sorted(f[:-len('.lst')] for f in os.listdir(plan)
                  if f.startswith(name + '_') and f.endswith('.tar.lst'))
    if not tars:
        die('no tar balls in the plan')
    unchecked = [t for t in tars if not (
        os.path.exists(os.path.join(state, 'done', t))
        and os.path.exists(os.path.join(state, 'md5', t + '.ok'))
        and os.path.exists(os.path.join(state, 'compare', t + '.ok')))]
    if unchecked:
        show('Tar balls without passed checks', unchecked)
        die('refusing to delete')
    print('Checks passed for all %d tar balls (packed, md5, compare)' % len(tars))

    pool = ThreadPoolExecutor(max_workers=args.jobs)

    if args.no_tape_check:
        print('Skipping the tape check (--no-tape-check)')
    else:
        print('Checking that every tar ball is written to tape ...')
        flags = archive_flags(dest, [t + ext for t in tars])
        not_on_tape = [t + ext for t, fl in zip(tars, flags) if not fl.startswith('a')]
        if not_on_tape:
            show('Tar balls not yet written to tape (flag a)', not_on_tape)
            die('try again later, the archive writes to tape in the background')
        print('All %d tar balls are on tape' % len(tars))

    # Compare each packed file with what it looked like when it was packed
    t0 = time.time()
    entries = []
    for t in tars:
        with open(os.path.join(state, 'manifest', t + '.tsv'), **ENC) as f:
            for line in f:
                entries.append(tuple(line.rstrip('\n').split('\t', 3)))
    packed = set(e[3] for e in entries)
    delete, changed, gone = [], [], 0
    nbytes = 0
    for result, path, size in pool.map(check_entry, entries, chunksize=256):
        if result == 'delete':
            delete.append(path)
            nbytes += size
        elif result == 'changed':
            changed.append(path)
        else:
            gone += 1
    print('Checked %d packed files in %.0f s' % (len(entries), time.time() - t0))

    # Anything under the source that is not in a tar ball stays
    t0 = time.time()
    present, dirs = walk_parallel(pool, source)
    leftovers = sorted(p for p in present if p not in packed)
    print('Listed %d files in %d directories in %.0f s' % (len(present), len(dirs), time.time() - t0))

    print('')
    print('Files to delete: %d (%.1f GB)' % (len(delete), nbytes / 1e9))
    print('Already gone:    %d' % gone)
    show('Changed since packing, kept', changed)
    show('Never packed, kept', leftovers)

    if not args.yes:
        print('')
        print('Dry run, nothing deleted. Re-run with --yes to delete %d files.' % len(delete))
        return

    t0 = time.time()
    errors = []
    logpath = os.path.join(state, 'deleted_%s.log' % time.strftime('%Y%m%d_%H%M%S'))
    with open(logpath, 'w', **ENC) as log:
        for path, err in zip(delete, pool.map(unlink, delete, chunksize=256)):
            if err:
                errors.append(err)
            else:
                log.write(path + '\n')
    for err in errors[:20]:
        print('could not delete ' + err)

    # Deepest directories first, so parents are empty by the time they come up
    removed_dirs = 0
    for d in sorted(dirs, key=lambda p: p.count('/'), reverse=True):
        try:
            os.rmdir(d)
            removed_dirs += 1
        except OSError:
            pass

    print('')
    print('Deleted %d files and %d empty directories in %.0f s, %d errors'
          % (len(delete) - len(errors), removed_dirs, time.time() - t0, len(errors)))
    print('List of deleted files: ' + logpath)
    if changed or leftovers or errors:
        print('Kept files remain in ' + source)


if __name__ == '__main__':
    main()
