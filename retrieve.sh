#!/bin/bash
#SBATCH --job-name=retrieve
#SBATCH --partition=shared
#SBATCH --account=bb1469
#SBATCH --time=2-00:00:00
#SBATCH --mem=16G
#SBATCH --output=retrieve_%j.log

# =============================================================================
# Retrieve data from the DKRZ Versity tape archive (ATLAS)
#
# Works on archive folders written by archive.sh (.tar or .tar.zst) and on
# folders written by 'packems -a'. Reads
# INDEX.txt to find which tar balls hold the requested files, stages them from
# tape, downloads them to scratch a few at a time, checks their md5 and
# unpacks them. Existing files are never overwritten.
#
# Usage:
#   1. Log in to the archive once (valid for 30 days):
#        module load tape && atlas login
#   2. Preview what would be fetched:
#        ./retrieve.sh --dry-run [--match REGEX] ARCHIVE_DIR
#   3. Submit:
#        sbatch retrieve.sh [--match REGEX] [--to DIR | --restore] ARCHIVE_DIR
#
# Example (only the restart files, into a new folder):
#   sbatch retrieve.sh --match '/restart/' --to /work/ab1234/$USER/restored \
#       /hsm/arch/ab1234/$USER/my_experiment
#
# Resubmitting the same command resumes: unpacked tar balls are skipped.
# =============================================================================

set -u
set -o pipefail

usage() {
    echo "Usage: sbatch retrieve.sh [OPTIONS] ARCHIVE_DIR"
    echo ""
    echo "Fetch and unpack files archived in ARCHIVE_DIR (/hsm/...)."
    echo ""
    echo "Options:"
    echo "  --match REGEX   Only files whose original path matches REGEX (Python syntax, repeatable;"
    echo "                  a file is taken if any REGEX matches). Only the tar balls holding them are fetched"
    echo "  --to DIR        Unpack below DIR (default /scratch/<u>/<user>/retrieve/<name>)"
    echo "  --restore       Unpack to the original paths instead of --to"
    echo "  --staging DIR   Where tar balls are downloaded (default /scratch/<u>/<user>/retrieve_staging/<name>)"
    echo "  --window N      Tar balls downloaded ahead of unpacking (default 3)"
    echo "  --keep-tars     Keep the downloaded tar balls"
    echo "  -n, --dry-run   Only show which files and tar balls would be fetched"
    echo "  -h, --help      Show this help message and exit"
    echo ""
    echo "Files are unpacked as <source folder name>/<path below it>, e.g. my_experiment/outdata/..."
    exit "${1:-0}"
}

log() {
    echo "[$(date '+%F %T')] $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Parse command line arguments
MATCHES=()
TARGET=""
RESTORE=false
STAGING=""
WINDOW=3
KEEP_TARS=false
DRY_RUN=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --match) MATCHES+=("$2"); shift ;;
        --to) TARGET=$2; shift ;;
        --restore) RESTORE=true ;;
        --staging) STAGING=$2; shift ;;
        --window) WINDOW=$2; shift ;;
        --keep-tars) KEEP_TARS=true ;;
        -n|--dry-run) DRY_RUN=true ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option: $1"; usage 1 ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done
[ ${#POSITIONAL[@]} -eq 1 ] || usage 1

ARCHIVE=${POSITIONAL[0]%/}
[[ $ARCHIVE == /hsm/* ]] || die "ARCHIVE_DIR must be in the archive (/hsm/...): $ARCHIVE"
NAME=$(basename "$ARCHIVE")
if $RESTORE && [ -n "$TARGET" ]; then
    die "Use either --to or --restore"
fi
if [ -z "$STAGING" ]; then
    STAGING="/scratch/${USER:0:1}/${USER}/retrieve_staging/${NAME}"
fi
# atlas can only write to /scratch
[[ $STAGING == /scratch/* ]] || die "Staging directory must be on /scratch: $STAGING"
if ! $RESTORE && [ -z "$TARGET" ]; then
    TARGET="/scratch/${USER:0:1}/${USER}/retrieve/${NAME}"
fi
[[ $WINDOW =~ ^[1-9][0-9]*$ ]] || die "--window needs a positive number: $WINDOW"
ZSTD=$(command -v zstd 2>/dev/null || true)

module load tape 2>/dev/null

echo "========================================"
echo "Versity Retrieve Script"
echo "Date: $(date)"
echo "User: $USER"
if $DRY_RUN; then
    echo "MODE: DRY RUN (nothing is staged, downloaded or unpacked)"
fi
echo "========================================"
echo ""
echo "Configuration:"
echo "  Archive:  $ARCHIVE"
if $RESTORE; then
    echo "  Unpack:   original paths (--restore)"
else
    echo "  Unpack:   $TARGET"
fi
echo "  Staging:  $STAGING"
if [ ${#MATCHES[@]} -gt 0 ]; then
    printf '  Match:    %s\n' "${MATCHES[@]}"
else
    echo "  Match:    all files"
fi
echo ""

STATUS=$(atlas status 2>&1)
grep -q '^User:' <<<"$STATUS" || die "Not logged in to the archive. Run: module load tape && atlas login"

mkdir -p "$STAGING"/{plan,tars,done,logs} || die "Cannot create $STAGING"

# =============================================================================
# atlas helpers: stage and copy run as server-side jobs
# =============================================================================

# Wait for an atlas job; print its details and return 0 only if it completed
wait_job() {
    local id=$1 out state errors=0 waited=0
    while true; do
        if ! out=$(atlas jobs get "$id" 2>&1); then
            errors=$((errors + 1))
            [ $errors -le 20 ] || { echo "$out"; return 1; }
        else
            state=$(awk '/^State:/ {print $2}' <<<"$out")
            case $state in
                completed) return 0 ;;
                failed|cancelled|canceled|error) echo "$out"; return 1 ;;
            esac
        fi
        sleep 30
        waited=$((waited + 30))
        if [ $waited -gt 172800 ]; then
            echo "atlas job $id did not finish within 48 h"
            return 1
        fi
    done
}

job_id() {
    sed -n 's/.*job submitted: *\([0-9][0-9]*\).*/\1/p' <<<"$1"
}

# Bring archive files online; stage jobs can take minutes to hours (tape mounts)
stage_files() {
    local out id
    out=$(atlas stage "$@" 2>&1)
    id=$(job_id "$out")
    [ -n "$id" ] || { echo "atlas stage did not start: $out"; return 1; }
    log "atlas stage job $id for $# file(s), waiting for tape ..."
    wait_job "$id"
}

# Start a copy of one archive file to $STAGING/tars/ and print the job id
start_copy() {
    local out id
    out=$(atlas cp --force "$1" "$STAGING/tars/" 2>&1)
    id=$(job_id "$out")
    [ -n "$id" ] || { echo "atlas cp did not start: $out" >&2; return 1; }
    echo "$id"
}

# Copy one archive file, staging it again if it fell out of the cache
copy_file() {
    local id
    id=$(start_copy "$1") || return 1
    if ! wait_job "$id" > "$STAGING/logs/copy_$(basename "$1").log"; then
        grep -q "stage it first" "$STAGING/logs/copy_$(basename "$1").log" || return 1
        stage_files "$1" || return 1
        id=$(start_copy "$1") || return 1
        wait_job "$id" > "$STAGING/logs/copy_$(basename "$1").log" || return 1
    fi
}

remote_md5() {
    atlas checksum "$1" 2>/dev/null | sed -n 's/.*: md5:\([0-9a-f]\{32\}\).*/\1/p' | head -1
}

# =============================================================================
# Plan: read INDEX.txt, pick files and the tar balls holding them
# =============================================================================

LISTING="$STAGING/plan/listing.json"
atlas ls -l --format json "$ARCHIVE/" > "$LISTING" 2>&1 || die "Cannot list $ARCHIVE: $(cat "$LISTING")"

INDEX="$STAGING/tars/INDEX.txt"
if [ ! -f "$STAGING/plan/INDEX.txt" ]; then
    log "Fetching INDEX.txt ..."
    flags=$(/usr/bin/python3 -I -c "
import json, sys
e = [x for x in json.load(open(sys.argv[1]))['entries'] if x['name'] == 'INDEX.txt']
print(e[0]['flags'] if e else 'missing')" "$LISTING")
    [ "$flags" != missing ] || die "No INDEX.txt in $ARCHIVE"
    if [ "${flags:1:1}" != o ]; then
        stage_files "$ARCHIVE/INDEX.txt" > "$STAGING/logs/stage_INDEX.txt.log" \
            || die "Staging INDEX.txt failed, see $STAGING/logs/stage_INDEX.txt.log"
    fi
    copy_file "$ARCHIVE/INDEX.txt" || die "Download of INDEX.txt failed, see $STAGING/logs/"
    mv "$INDEX" "$STAGING/plan/INDEX.txt"
fi

# A staging directory belongs to one selection and one target
SELECTION="$STAGING/plan/selection"
{
    echo "ARCHIVE $ARCHIVE"
    if $RESTORE; then echo "RESTORE"; else echo "TARGET $TARGET"; fi
    printf 'MATCH %s\n' "${MATCHES[@]+"${MATCHES[@]}"}"
} > "$SELECTION.new"
if [ -f "$SELECTION" ] && ! cmp -s "$SELECTION" "$SELECTION.new"; then
    rm -f "$SELECTION.new"
    die "$STAGING was used for a different selection, see $SELECTION (pass another --staging)"
fi
mv "$SELECTION.new" "$SELECTION"

/usr/bin/python3 -I - "$STAGING/plan" "$LISTING" "$RESTORE" "${MATCHES[@]+"${MATCHES[@]}"}" <<'EOF' \
    || die "Could not read INDEX.txt"
import json, os, re, sys
plan, listing, restore, patterns = sys.argv[1], sys.argv[2], sys.argv[3] == 'true', sys.argv[4:]
regexes = [re.compile(p) for p in patterns]
ENC = dict(encoding='utf-8', errors='surrogateescape')

header, entries, in_body = [], [], False
with open(os.path.join(plan, 'INDEX.txt'), **ENC) as f:
    for line in f:
        line = line.rstrip('\n')
        if not in_body:
            if line == '---':
                in_body = True
            else:
                header.append(line)
            continue
        head, sep, tar = line.rpartition(' -> ')
        parts = head.split(None, 5)
        if not sep or len(parts) < 6:
            continue
        perm, size, path = parts[0], parts[2], parts[5]
        if perm.startswith('l'):
            path = path.split(' -> ', 1)[0]
        elif perm.startswith('h'):
            path = path.split(' link to ', 1)[0]
        entries.append((tar, path, int(size) if size.isdigit() else 0))

# archive.sh writes the source folder first; packems puts it last on its command line
source = ''
if len(header) > 1 and header[1].startswith('archived to:'):
    source = header[0]
else:
    for h in header:
        if h.startswith('command_line:') and h.split()[-1].startswith('/'):
            source = h.split()[-1]
if not source and entries:
    source = os.path.commonpath([p for _, p, _ in entries])
source = source.rstrip('/')
# Keep the source folder's own name: strip the components of its parent
strip = 0 if restore else len([c for c in os.path.dirname(source).split('/') if c])

online, sizes = {}, {}
for e in json.load(open(listing))['entries']:
    online[e['name']] = e.get('flags', '')[1:2] == 'o'
    sizes[e['name']] = e.get('size', 0)

members, nbytes = {}, 0
for tar, path, size in entries:
    if regexes and not any(r.search(path) for r in regexes):
        continue
    members.setdefault(tar, []).append(path.lstrip('/'))
    nbytes += size

missing = [t for t in members if t not in sizes]
with open(os.path.join(plan, 'tars.txt'), 'w') as out:
    for tar in sorted(members):
        with open(os.path.join(plan, tar + '.members'), 'w', **ENC) as m:
            m.write('\n'.join(members[tar]) + '\n')
        out.write('%s\t%d\t%d\t%d\n' % (tar, len(members[tar]), sizes.get(tar, 0), online.get(tar, False)))
with open(os.path.join(plan, 'info'), 'w') as out:
    out.write('SOURCE\t%s\nSTRIP\t%d\n' % (source, strip))

print('Source folder: %s' % source)
print('Files:         %d of %d (%.1f GB unpacked)' % (sum(len(v) for v in members.values()), len(entries), nbytes / 1e9))
print('Tar balls:     %d, %.1f GB to download, %d already online'
      % (len(members), sum(sizes.get(t, 0) for t in members) / 1e9, sum(online.get(t, False) for t in members)))
if missing:
    print('ERROR: tar balls listed in INDEX.txt but not in the archive: ' + ' '.join(sorted(missing)))
    sys.exit(1)
EOF

SOURCE=$(awk -F '\t' '$1 == "SOURCE" {print $2}' "$STAGING/plan/info")
STRIP=$(awk -F '\t' '$1 == "STRIP" {print $2}' "$STAGING/plan/info")
mapfile -t TARS < <(cut -f1 "$STAGING/plan/tars.txt")
[ ${#TARS[@]} -gt 0 ] || die "No files match"
if $RESTORE; then
    log "Unpacking to the original paths below $SOURCE"
else
    log "Unpacking to $TARGET/$(basename "$SOURCE")/..."
fi

if $DRY_RUN; then
    echo ""
    echo "Tar balls (files selected, size in GB, online):"
    awk -F '\t' '{printf "  %s  %d files  %.1f GB  %s\n", $1, $2, $3 / 1e9, $4 ? "online" : "on tape"}' "$STAGING/plan/tars.txt"
    echo ""
    echo "Dry run complete - nothing was staged, downloaded or unpacked"
    exit 0
fi

if grep -q '\.zst$' "$STAGING/plan/tars.txt"; then
    [ -n "$ZSTD" ] || die "zstd not found in PATH, needed for .tar.zst"
fi

# =============================================================================
# Stage, download (WINDOW ahead), check md5, unpack
# =============================================================================

TODO=()
for t in "${TARS[@]}"; do
    [ -f "$STAGING/done/$t" ] || TODO+=("$t")
done
log "${#TODO[@]} of ${#TARS[@]} tar balls left to unpack"

offline=()
for t in "${TODO[@]}"; do
    awk -F '\t' -v t="$t" '$1 == t && $4 == 0 {found = 1} END {exit !found}' "$STAGING/plan/tars.txt" \
        && offline+=("$ARCHIVE/$t")
done
if [ ${#offline[@]} -gt 0 ]; then
    stage_files "${offline[@]}" > "$STAGING/logs/stage.log" || die "Staging failed, see $STAGING/logs/stage.log"
    log "Staging done"
fi

if ! $RESTORE; then
    mkdir -p "$TARGET" || die "Cannot create $TARGET"
fi

START=$SECONDS
declare -A COPY_JOB=()
next=0
start_next() {
    while [ $next -lt ${#TODO[@]} ] && [ ${#COPY_JOB[@]} -lt "$WINDOW" ]; do
        local t=${TODO[$next]}
        if [ ! -f "$STAGING/tars/$t" ]; then
            COPY_JOB[$t]=$(start_copy "$ARCHIVE/$t") || die "Could not start download of $t"
        else
            COPY_JOB[$t]=local
        fi
        next=$((next + 1))
    done
}

for t in "${TODO[@]}"; do
    start_next
    tarfile="$STAGING/tars/$t"
    if [ "${COPY_JOB[$t]}" != local ]; then
        if ! wait_job "${COPY_JOB[$t]}" > "$STAGING/logs/copy_$t.log"; then
            # The cache gives no guarantee that staged files stay online
            grep -q "stage it first" "$STAGING/logs/copy_$t.log" || die "Download of $t failed, see $STAGING/logs/copy_$t.log"
            copy_file "$ARCHIVE/$t" || die "Download of $t failed, see $STAGING/logs/copy_$t.log"
        fi
    fi
    unset "COPY_JOB[$t]"
    start_next

    r=$(remote_md5 "$ARCHIVE/$t")
    if [ -n "$r" ]; then
        l=$(md5sum "$tarfile" | cut -d' ' -f1)
        [ "$l" = "$r" ] || die "$t: md5 mismatch, local $l, archive $r"
        check="md5 ok"
    else
        # Tar balls from packems have no md5; atlas cp verified the copy with sha1
        check="no md5 in archive, copy verified by atlas"
    fi

    t0=$SECONDS
    # -C only applies to names after it on the command line, so it must precede -T
    if $RESTORE; then
        tarflags=(-b 2048 -x --skip-old-files -C /)
    else
        tarflags=(-b 2048 -x --skip-old-files -C "$TARGET" --strip-components="$STRIP")
    fi
    tarflags+=(--verbatim-files-from -T "$STAGING/plan/$t.members")
    if [[ $t == *.zst ]]; then
        "$ZSTD" -dcq "$tarfile" | tar "${tarflags[@]}" -f - 2> "$STAGING/logs/unpack_$t.err"
        rcs=("${PIPESTATUS[@]}")
    else
        tar "${tarflags[@]}" -f "$tarfile" 2> "$STAGING/logs/unpack_$t.err"
        rcs=($? 0)
    fi
    [ "${rcs[1]}" -eq 0 ] || die "$t: zstd exited with ${rcs[1]}, see $STAGING/logs/unpack_$t.err"
    [ "${rcs[0]}" -eq 0 ] || die "$t: tar exited with ${rcs[0]}, see $STAGING/logs/unpack_$t.err"

    date '+%F %T' > "$STAGING/done/$t"
    $KEEP_TARS || rm -f "$tarfile"
    log "$t: $(awk -F '\t' -v t="$t" '$1 == t {print $2}' "$STAGING/plan/tars.txt") files unpacked in $((SECONDS - t0)) s ($check)"
done

for t in "${TARS[@]}"; do
    [ -f "$STAGING/done/$t" ] || die "$t was not unpacked; resubmit the same command to resume"
done

ELAPSED=$((SECONDS - START))
echo ""
echo "========================================"
log "Retrieve complete: ${#TARS[@]} tar balls, run time $((ELAPSED / 3600))h $((ELAPSED % 3600 / 60))m"
if $RESTORE; then
    echo "  Files restored to their original paths below $SOURCE"
else
    echo "  Files are in $TARGET/$(basename "$SOURCE")"
fi
echo "  Existing files were left untouched (tar --skip-old-files)"
$KEEP_TARS && echo "  Downloaded tar balls kept in $STAGING/tars"
echo "========================================"
