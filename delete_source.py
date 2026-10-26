#!/usr/bin/env python3
"""Delete source files that archive.sh has packed, uploaded and verified.

Called through the delete_source.sh that archive.sh writes to its state
directory once every tar ball passed the packing, md5 and compare checks.

Dry run by default; pass --yes to delete. A file is only removed if its type,
size and mtime still match what was packed. Directories left empty afterwards
are removed too. Files that were never packed are listed and kept.
"""

import argparse
import json
import os
import subprocess
import sys
import time

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


def archive_flags(path):
    """Return the ScoutAM flags of one archived file, e.g. 'a-o-v'."""
    out = subprocess.run(['atlas', 'ls', '-l', '--format', 'json', path],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         universal_newlines=True)
    if out.returncode != 0:
        die('atlas ls %s failed: %s' % (path, out.stdout.strip()))
    entries = json.loads(out.stdout).get('entries', [])
    return entries[0].get('flags', '') if entries else ''


def show(title, paths, limit=20):
    print('%s: %d' % (title, len(paths)))
    for p in paths[:limit]:
        print('    ' + p)
    if len(paths) > limit:
        print('    ... (%d more)' % (len(paths) - limit))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('state', help='state directory written by archive.sh')
    parser.add_argument('--yes', action='store_true', help='actually delete')
    parser.add_argument('--no-tape-check', action='store_true',
                        help='do not require the tar balls to be written to tape')
    args = parser.parse_args()

    state = os.path.abspath(args.state)
    cfg = read_config(state)
    source, dest, name = cfg['SOURCE'], cfg['DEST'], cfg['NAME']
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

    if args.no_tape_check:
        print('Skipping the tape check (--no-tape-check)')
    else:
        print('Checking that every tar ball is written to tape ...')
        not_on_tape = [t for t in tars if not archive_flags(dest + '/' + t).startswith('a')]
        if not_on_tape:
            show('Tar balls not yet written to tape (flag a)', not_on_tape)
            die('try again later, the archive writes to tape in the background')
        print('All %d tar balls are on tape' % len(tars))

    # Compare each packed file with what it looked like when it was packed
    delete, changed, gone = [], [], 0
    nbytes = 0
    packed = set()
    for t in tars:
        with open(os.path.join(state, 'manifest', t + '.tsv'), **ENC) as f:
            for line in f:
                kind, size, mtime, path = line.rstrip('\n').split('\t', 3)
                packed.add(path)
                try:
                    st = os.lstat(path)
                except FileNotFoundError:
                    gone += 1
                    continue
                now_kind = 'l' if os.path.islink(path) else 'f' if os.path.isfile(path) else 'o'
                if (now_kind, st.st_size, st.st_mtime_ns) == (kind, int(size), int(mtime)):
                    delete.append(path)
                    nbytes += st.st_size
                else:
                    changed.append(path)

    # Anything under the source that is not in a tar ball stays
    leftovers = []
    for root, dirs, files in os.walk(source):
        for fn in files:
            p = os.path.join(root, fn)
            if p not in packed:
                leftovers.append(p)

    print('')
    print('Files to delete: %d (%.1f GB)' % (len(delete), nbytes / 1e9))
    print('Already gone:    %d' % gone)
    show('Changed since packing, kept', changed)
    show('Never packed, kept', leftovers)

    if not args.yes:
        print('')
        print('Dry run, nothing deleted. Re-run with --yes to delete %d files.' % len(delete))
        return

    logpath = os.path.join(state, 'deleted_%s.log' % time.strftime('%Y%m%d_%H%M%S'))
    errors = 0
    with open(logpath, 'w', **ENC) as log:
        for path in delete:
            try:
                os.unlink(path)
                log.write(path + '\n')
            except OSError as e:
                errors += 1
                print('could not delete %s: %s' % (path, e))
    removed_dirs = 0
    for root, dirs, files in os.walk(source, topdown=False):
        if root == source:
            continue
        try:
            os.rmdir(root)
            removed_dirs += 1
        except OSError:
            pass

    print('')
    print('Deleted %d files and %d empty directories, %d errors' % (len(delete) - errors, removed_dirs, errors))
    print('List of deleted files: ' + logpath)
    if changed or leftovers:
        print('Kept files remain in ' + source)


if __name__ == '__main__':
    main()
