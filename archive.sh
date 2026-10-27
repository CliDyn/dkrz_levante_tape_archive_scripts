#!/bin/bash
#SBATCH --job-name=archive
#SBATCH --partition=shared
#SBATCH --account=bb1469
#SBATCH --time=7-00:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --output=archive_%j.log

# =============================================================================
# Archive a directory to the DKRZ Versity tape archive (ATLAS)
#
# Packs SOURCE into ~190 GB tar balls (packems plans the split, tar packs) and
# uploads each tar ball with 'atlas cp --checksum md5' while the next one is
# being packed. The source is never modified. When every tar ball has passed
# all checks, a delete_source.sh is written to the state directory so the
# source can be removed by hand.
#
# Usage:
#   1. Log in to the archive once (valid for 30 days):
#        module load tape && atlas login
#   2. Preview the plan:
#        ./archive.sh --dry-run SOURCE DEST
#   3. Submit:
#        sbatch archive.sh --md5 --compare --delete-scratch SOURCE DEST
#
# Example:
#   sbatch archive.sh --md5 --compare --delete-scratch \
#       /work/bb1469/a270092/runtime/lpjg-spinup-develop/lpj_spinup_HR_2000y \
#       /hsm/arch/bb1469/a270092/lpjg-spinup-develop/lpj_spinup_HR_2000y
#
# Resubmitting the same command resumes: finished tar balls are skipped.
# =============================================================================

set -u
set -o pipefail

usage() {
    echo "Usage: sbatch archive.sh [OPTIONS] SOURCE DEST"
    echo ""
    echo "Pack SOURCE into tar balls and upload them to DEST (/hsm/...) with atlas."
    echo ""
    echo "Options:"
    echo "  --md5             Compare md5sum of each local tar ball with the md5 stored in the archive"
    echo "  --compare         Compare each tar ball against the source files (tar --compare)"
    echo "  --delete-scratch  Remove each staged tar ball once all enabled checks passed (needs --md5)"
    echo "  --window N        Max finished tar balls waiting on scratch (default 3, with --delete-scratch)"
    echo "  --target-gb N     Target tar ball size in GB before compression (default 190)"
    echo "  --max-gb N        Maximum tar ball size in GB before compression (default 200)"
    echo "  --zstd            Compress tar balls with zstd (.tar.zst), using all CPUs of the job"
    echo "  --zstd-level N    zstd compression level (default 3, implies --zstd)"
    echo "  --group NAME      Group of archived files and created folders (default: project in DEST, e.g. bb1469)"
    echo "  --staging DIR     Where tar balls are written (default /scratch/<u>/<user>/archive_staging/<name>)"
    echo "  --state DIR       Plan, logs and checksums (default /work/<project>/<user>/archive_state/<name>)"
    echo "  -n, --dry-run     Only create and show the packing plan"
    echo "  -h, --help        Show this help message and exit"
    echo ""
    echo "delete_source.sh is only written when --md5 and --compare were used and every check passed."
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
MD5=false
COMPARE=false
DELETE_SCRATCH=false
DRY_RUN=false
WINDOW=3
TARGET_GB=190
MAX_GB=200
STAGING=""
STATE=""
GROUP=""
ZSTD_LEVEL=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --md5) MD5=true ;;
        --compare) COMPARE=true ;;
        --delete-scratch) DELETE_SCRATCH=true ;;
        --window) WINDOW=$2; shift ;;
        --target-gb) TARGET_GB=$2; shift ;;
        --max-gb) MAX_GB=$2; shift ;;
        --group) GROUP=$2; shift ;;
        --zstd) ZSTD_LEVEL=${ZSTD_LEVEL:-3} ;;
        --zstd-level) ZSTD_LEVEL=$2; shift ;;
        --staging) STAGING=$2; shift ;;
        --state) STATE=$2; shift ;;
        -n|--dry-run) DRY_RUN=true ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option: $1"; usage 1 ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done
[ ${#POSITIONAL[@]} -eq 2 ] || usage 1

SOURCE=$(realpath -e "${POSITIONAL[0]}") || die "Source does not exist: ${POSITIONAL[0]}"
[ -d "$SOURCE" ] || die "Source is not a directory: $SOURCE"
DEST=${POSITIONAL[1]%/}
[[ $DEST == /hsm/* ]] || die "Destination must be in the archive (/hsm/...): $DEST"
NAME=$(basename "$SOURCE")

if [ -z "$STAGING" ]; then
    STAGING="/scratch/${USER:0:1}/${USER}/archive_staging/${NAME}"
fi
if [ -z "$STATE" ]; then
    [[ $SOURCE =~ ^/work/([^/]+)/ ]] || die "Cannot derive a project from $SOURCE, pass --state"
    STATE="/work/${BASH_REMATCH[1]}/${USER}/archive_state/${NAME}"
fi
case "$STATE/" in "$SOURCE"/*) die "State directory must not be inside the source: $STATE" ;; esac
case "$STAGING/" in "$SOURCE"/*) die "Staging directory must not be inside the source: $STAGING" ;; esac
if $DELETE_SCRATCH && ! $MD5; then
    die "--delete-scratch needs --md5"
fi

# atlas gives new files the user's primary group, so set the group afterwards
if [ -z "$GROUP" ]; then
    [[ $DEST =~ ^/hsm/[^/]+/([^/]+)/ ]] || die "Cannot derive a group from $DEST, pass --group"
    GROUP=${BASH_REMATCH[1]}
fi
id -Gn | tr ' ' '\n' | grep -qxF "$GROUP" || die "You are not a member of group $GROUP"
OWNER="$(id -u):$(getent group "$GROUP" | cut -d: -f3)"

# zstd is not a module; look it up before 'module purge' changes PATH
EXT=""
COMPRESS=none
if [ -n "$ZSTD_LEVEL" ]; then
    [[ $ZSTD_LEVEL =~ ^[0-9]+$ ]] || die "--zstd-level needs a number: $ZSTD_LEVEL"
    ZSTD=$(command -v zstd) || die "zstd not found in PATH"
    THREADS=${SLURM_CPUS_PER_TASK:-4}
    EXT=.zst
    COMPRESS=zstd
fi

# The batch script runs from a spool copy, so locate the repository through Slurm
if [ -n "${SLURM_JOB_ID:-}" ]; then
    SCRIPT_PATH=$(scontrol show job "$SLURM_JOB_ID" | sed -n 's/^ *Command=\([^ ]*\).*/\1/p')
else
    SCRIPT_PATH=$(realpath "${BASH_SOURCE[0]}")
fi
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
[ -f "$SCRIPT_DIR/delete_source.py" ] || die "delete_source.py not found next to $SCRIPT_PATH"

module purge
module load packems tape 2>/dev/null

echo "========================================"
echo "Versity Archive Script"
echo "Date: $(date)"
echo "User: $USER"
if $DRY_RUN; then
    echo "MODE: DRY RUN (only the packing plan is created)"
fi
echo "========================================"
echo ""
echo "Configuration:"
echo "  Source:         $SOURCE"
echo "  Archive:        $DEST"
echo "  Staging:        $STAGING"
echo "  State:          $STATE"
echo "  Group:          $GROUP"
echo "  Tar size:       ${TARGET_GB}GB (max ${MAX_GB}GB) before compression"
if [ -n "$EXT" ]; then
    echo "  Compression:    zstd level $ZSTD_LEVEL, $THREADS threads"
else
    echo "  Compression:    none"
fi
echo "  md5 check:      $MD5"
echo "  tar compare:    $COMPARE"
echo "  Delete scratch: $DELETE_SCRATCH (window $WINDOW)"
echo ""

if ! $DRY_RUN; then
    STATUS=$(atlas status 2>&1)
    grep -q '^User:' <<<"$STATUS" || die "Not logged in to the archive. Run: module load tape && atlas login"
    log "atlas $(grep '^Session:' <<<"$STATUS")"
fi

mkdir -p "$STATE"/{plan,idx,manifest,md5,compare,packed,done,logs} || die "Cannot create $STATE"
mkdir -p "$STAGING" || die "Cannot create $STAGING"

# A state directory belongs to one source and destination
CONFIG="$STATE/config"
if [ -f "$CONFIG" ]; then
    grep -qxF "SOURCE	$SOURCE" "$CONFIG" && grep -qxF "DEST	$DEST" "$CONFIG" \
        || die "$STATE was used for a different source or destination, see $CONFIG"
    old=$(awk -F '\t' '$1 == "COMPRESS" {print $2}' "$CONFIG")
    [ "${old:-none}" = "$COMPRESS" ] \
        || die "$STATE was used with compression '${old:-none}', this run uses '$COMPRESS'"
else
    printf 'SOURCE\t%s\nDEST\t%s\nNAME\t%s\nCOMPRESS\t%s\n' "$SOURCE" "$DEST" "$NAME" "$COMPRESS" > "$CONFIG"
fi

# Archive folders this run creates get $GROUP at the end; existing ones are left alone
if ! $DRY_RUN && [ ! -f "$STATE/new_dirs" ]; then
    p=$DEST
    while [[ $p == /hsm/*/* ]] && ! atlas ls "$p/" > /dev/null 2>&1; do
        echo "$p"
        p=$(dirname "$p")
    done > "$STATE/new_dirs"
fi
cp "$SCRIPT_DIR/delete_source.py" "$STATE/delete_source.py"

# A previous failure is kept for reference; this run starts clean
if [ -f "$STATE/FAILED" ]; then
    mv "$STATE/FAILED" "$STATE/FAILED.$(date +%Y%m%d_%H%M%S)"
fi
rm -f "$STATE/ALL_OK" "$STATE/delete_source.sh"

# =============================================================================
# Plan: packems -N writes one file list (.lst) per tar ball without packing
# =============================================================================

PLAN="$STATE/plan"
if [ ! -f "$STATE/plan.ok" ]; then
    log "Planning tar balls with packems (scans the whole source) ..."
    rm -f "$PLAN"/*
    (cd "$PLAN" && packems -N -t "$TARGET_GB" -m "$MAX_GB" -o "$NAME" -d "$PLAN" -S "$DEST" "$SOURCE") \
        > "$STATE/plan.log" 2>&1
    rc=$?
    [ $rc -eq 0 ] || die "packems planning failed (exit $rc), see $STATE/plan.log"
    touch "$STATE/plan.ok"
fi
mapfile -t LISTS < <(ls "$PLAN"/"${NAME}"_*.tar.lst 2>/dev/null | sort)
[ ${#LISTS[@]} -gt 0 ] || die "packems planned no tar balls, see $STATE/plan.log"
TOTAL=${#LISTS[@]}
NFILES=$(cat "${LISTS[@]}" | wc -l)
log "Plan: $TOTAL tar balls, $NFILES files, $(tail -1 "$STATE/plan.log") GB"

if $DRY_RUN; then
    echo ""
    echo "Planned tar ball sizes (GB):"
    grep -E "${NAME}_[0-9]+\.tar$" "$STATE/plan.log"
    echo ""
    echo "Dry run complete - nothing was packed or uploaded"
    exit 0
fi

# =============================================================================
# Per tar ball: upload, md5 and compare run in a background worker
# =============================================================================

fail() {
    echo "$*" >> "$STATE/FAILED"
    log "FAILED: $*"
}

# Copy one file to $DEST with atlas and wait for the copy job to end
upload_file() {
    local src=$1 out id state items errors=0 waited=0
    out=$(atlas cp --force --checksum md5 "$src" "$DEST/" 2>&1)
    id=$(sed -n 's/.*copy job submitted: *\([0-9][0-9]*\).*/\1/p' <<<"$out")
    if [ -z "$id" ]; then
        echo "atlas cp did not start: $out"
        return 1
    fi
    echo "atlas copy job $id started for $(basename "$src")"
    while true; do
        sleep 30
        waited=$((waited + 30))
        if [ $waited -gt 86400 ]; then
            echo "atlas copy job $id did not finish within 24 h"
            return 1
        fi
        if ! out=$(atlas jobs get "$id" 2>&1); then
            errors=$((errors + 1))
            [ $errors -le 20 ] && continue
            echo "atlas jobs get $id keeps failing: $out"
            return 1
        fi
        state=$(awk '/^State:/ {print $2}' <<<"$out")
        case $state in
            completed)
                items=$(awk '/^Items:/ {print $2, $4}' <<<"$out")
                if [ "${items% *}" = "${items#* }" ]; then
                    echo "atlas copy job $id completed ($items items)"
                    return 0
                fi
                echo "atlas copy job $id completed with missing items: $out"
                return 1
                ;;
            failed|cancelled|canceled|error)
                echo "atlas copy job $id ended as $state: $out"
                return 1
                ;;
        esac
    done
}

remote_md5() {
    atlas checksum "$1" 2>/dev/null | sed -n 's/.*: md5:\([0-9a-f]\{32\}\).*/\1/p' | head -1
}

process_tar() {
    local n=$1
    local f="$n$EXT"
    local tarfile="$STAGING/$f" pid_md5="" pid_cmp="" ok=true rc l r
    local t0=$SECONDS

    if $MD5; then
        md5sum "$tarfile" > "$STATE/md5/$n.local" &
        pid_md5=$!
    fi
    if $COMPARE; then
        if [ -n "$EXT" ]; then
            { "$ZSTD" -dcq "$tarfile" | tar -b 2048 -C / -df -; } > "$STATE/logs/$n.compare" 2>&1 &
        else
            tar -b 2048 -C / -df "$tarfile" > "$STATE/logs/$n.compare" 2>&1 &
        fi
        pid_cmp=$!
    fi

    if upload_file "$tarfile"; then
        if ! atlas chown "$OWNER" "$DEST/$f"; then
            echo "atlas chown $OWNER $DEST/$f failed"
            ok=false
        fi
    else
        ok=false
    fi

    if [ -n "$pid_md5" ] && ! wait "$pid_md5"; then
        echo "md5sum of $tarfile failed"
        ok=false
    fi
    if [ -n "$pid_cmp" ]; then
        wait "$pid_cmp"
        rc=$?
        if [ $rc -eq 0 ]; then
            touch "$STATE/compare/$n.ok"
        else
            echo "tar --compare found differences (exit $rc), see $STATE/logs/$n.compare"
            ok=false
        fi
    fi
    if $MD5 && $ok; then
        l=$(cut -d' ' -f1 "$STATE/md5/$n.local")
        r=$(remote_md5 "$DEST/$f")
        if [ -n "$l" ] && [ "$l" = "$r" ]; then
            echo "$l" > "$STATE/md5/$n.ok"
            echo "md5 matches archive: $l"
        else
            echo "md5 mismatch: local '$l', archive '$r'"
            ok=false
        fi
    fi

    if ! $ok; then
        fail "$n: checks failed, tar ball kept in $STAGING, see $STATE/logs/$n.log"
        return 1
    fi
    if $DELETE_SCRATCH; then
        rm -f "$tarfile" && echo "removed $tarfile"
    fi
    date '+%F %T' > "$STATE/done/$n"
    log "$n: uploaded and verified in $((SECONDS - t0)) s"
}

# Record type, size and mtime of each packed file for delete_source.py
write_manifest() {
    /usr/bin/python3 -I - "$1" "$2" <<'EOF'
import os, stat, sys
with open(sys.argv[1], encoding='utf-8', errors='surrogateescape') as lst, \
     open(sys.argv[2] + '~', 'w', encoding='utf-8', errors='surrogateescape') as out:
    for line in lst:
        path = line.rstrip('\n')
        if not path:
            continue
        st = os.lstat(path)
        kind = 'l' if stat.S_ISLNK(st.st_mode) else 'f' if stat.S_ISREG(st.st_mode) else 'o'
        out.write('%s\t%d\t%d\t%s\n' % (kind, st.st_size, st.st_mtime_ns, path))
os.rename(sys.argv[2] + '~', sys.argv[2])
EOF
}

staged_count() {
    find "$STAGING" -maxdepth 1 -type f -name "${NAME}_*.tar$EXT" | wc -l
}

if ! $DELETE_SCRATCH; then
    log "WARNING: without --delete-scratch all tar balls stay on scratch (needs space for the whole source)"
fi

START=$SECONDS
RAW_BYTES=0
PACKED_BYTES=0
for lst in "${LISTS[@]}"; do
    n=$(basename "$lst" .lst)
    f="$n$EXT"
    [ -f "$STATE/done/$n" ] && continue
    [ -f "$STATE/FAILED" ] && break

    if $DELETE_SCRATCH; then
        while [ "$(staged_count)" -ge "$WINDOW" ] && [ ! -f "$STATE/FAILED" ]; do
            sleep 30
        done
        [ -f "$STATE/FAILED" ] && break
    fi

    if [ -f "$STATE/packed/$n" ] && [ -f "$STAGING/$f" ]; then
        log "$f: already packed, resuming upload"
    else
        log "$f: packing $(wc -l < "$lst") files ..."
        t0=$SECONDS
        rm -f "$STAGING/$f" "$STAGING/$f~" "$STATE/packed/$n"
        if [ -n "$EXT" ]; then
            tar -b 2048 --index-file="$STATE/idx/$n.idx" -cvvf - -T "$lst" 2> "$STATE/logs/$n.tar.err" \
                | "$ZSTD" "-$ZSTD_LEVEL" -T"$THREADS" -q -o "$STAGING/$f~" 2> "$STATE/logs/$n.zstd.err"
            rcs=("${PIPESTATUS[@]}")
        else
            tar -b 2048 --index-file="$STATE/idx/$n.idx" -cvvf "$STAGING/$f~" -T "$lst" \
                > /dev/null 2> "$STATE/logs/$n.tar.err"
            rcs=($? 0)
        fi
        # tar exit 1 means a file changed while it was read, 2 a file could not be read
        if [ "${rcs[0]}" -ne 0 ]; then
            fail "$f: tar exited with ${rcs[0]}, see $STATE/logs/$n.tar.err"
            break
        fi
        if [ "${rcs[1]}" -ne 0 ]; then
            fail "$f: zstd exited with ${rcs[1]}, see $STATE/logs/$n.zstd.err"
            break
        fi
        mv "$STAGING/$f~" "$STAGING/$f"
        if ! write_manifest "$lst" "$STATE/manifest/$n.tsv" 2> "$STATE/logs/$n.manifest.err"; then
            fail "$f: could not record file sizes, see $STATE/logs/$n.manifest.err"
            break
        fi
        touch "$STATE/packed/$n"
        raw=$(awk -F '\t' '{s += $2} END {printf "%d", s}' "$STATE/manifest/$n.tsv")
        size=$(stat -c %s "$STAGING/$f")
        RAW_BYTES=$((RAW_BYTES + raw))
        PACKED_BYTES=$((PACKED_BYTES + size))
        dt=$((SECONDS - t0))
        log "$f: packed $(awk -v r="$raw" -v s="$size" 'BEGIN {printf "%.1f GB into %.1f GB (%.1fx)", r / 1e9, s / 1e9, r / (s > 0 ? s : 1)}') in ${dt} s ($((raw / (dt > 0 ? dt : 1) / 1000000)) MB/s read)"
    fi

    process_tar "$n" > "$STATE/logs/$n.log" 2>&1 &
done

log "Waiting for running uploads to finish ..."
wait

NDONE=$(find "$STATE/done" -maxdepth 1 -type f -name "${NAME}_*.tar" | wc -l)
ELAPSED=$((SECONDS - START))
echo ""
echo "========================================"
log "$NDONE of $TOTAL tar balls uploaded and verified, run time $((ELAPSED / 3600))h $((ELAPSED % 3600 / 60))m"
if [ $RAW_BYTES -gt 0 ] && [ $ELAPSED -gt 0 ]; then
    log "Packed $(awk -v r="$RAW_BYTES" -v s="$PACKED_BYTES" 'BEGIN {printf "%.1f GB into %.1f GB (%.1fx)", r / 1e9, s / 1e9, r / s}') in this run, $((RAW_BYTES / ELAPSED / 1000000)) MB/s end to end"
fi
if [ -f "$STATE/FAILED" ] || [ "$NDONE" -ne "$TOTAL" ]; then
    [ -f "$STATE/FAILED" ] && cat "$STATE/FAILED"
    log "Archive INCOMPLETE. Fix the problem and resubmit the same command to resume."
    exit 1
fi

# =============================================================================
# Index and metadata: INDEX.txt maps every file to its tar ball
# =============================================================================

log "Writing INDEX.txt and ${NAME}_meta.tar ..."
{
    echo "$SOURCE"
    echo "archived to: $DEST"
    echo "date: $(date)"
    echo "---"
    for lst in "${LISTS[@]}"; do
        n=$(basename "$lst" .lst)
        awk -v t="$n$EXT" '{print $0 " -> " t}' "$STATE/idx/$n.idx"
    done
} > "$STATE/INDEX.txt"
tar -C "$STATE" -cf "$STAGING/${NAME}_meta.tar" config plan.log plan idx manifest md5 compare logs INDEX.txt \
    || die "Could not create ${NAME}_meta.tar"

for f in "$STATE/INDEX.txt" "$STAGING/${NAME}_meta.tar"; do
    upload_file "$f" > "$STATE/logs/$(basename "$f").log" 2>&1 \
        || die "Upload of $f failed, see $STATE/logs/$(basename "$f").log"
    l=$(md5sum "$f" | cut -d' ' -f1)
    r=$(remote_md5 "$DEST/$(basename "$f")")
    [ "$l" = "$r" ] || die "md5 mismatch for $(basename "$f"): local $l, archive $r"
    atlas chown "$OWNER" "$DEST/$(basename "$f")" > /dev/null || die "atlas chown of $(basename "$f") failed"
done
rm -f "$STAGING/${NAME}_meta.tar"
while read -r d; do
    atlas chown "$OWNER" "$d" > /dev/null || die "atlas chown of $d failed"
done < "$STATE/new_dirs"

echo ""
echo "========================================"
log "Archive complete: $DEST"
echo "  INDEX.txt (which file is in which tar ball): $DEST/INDEX.txt"
echo "  Local copy of plan, logs and checksums:      $STATE"

if $MD5 && $COMPARE; then
    touch "$STATE/ALL_OK"
    cat > "$STATE/delete_source.sh" <<EOF
#!/bin/bash
# Delete the archived source files of $NAME.
# Dry run by default; add --yes to delete. Refuses until every tar ball is on tape.
module load tape 2>/dev/null
exec /usr/bin/python3 -I "$STATE/delete_source.py" "$STATE" "\$@"
EOF
    chmod +x "$STATE/delete_source.sh"
    echo ""
    echo "All tar balls passed packing, md5 and compare checks."
    echo "To remove the source once the archive reports the tar balls on tape:"
    echo "  $STATE/delete_source.sh          # dry run"
    echo "  $STATE/delete_source.sh --yes    # delete"
else
    echo ""
    echo "delete_source.sh was not written: it needs a run with --md5 and --compare."
fi
echo "========================================"
