#!/bin/bash
#SBATCH --job-name=retrieve_packems
#SBATCH --partition=shared
#SBATCH --account=ab0995
#SBATCH --time=24:00:00
#SBATCH --mem=16G
#SBATCH --output=retrieve_packems_%j.log
#SBATCH --error=retrieve_packems_%j.err

# =============================================================================
# Retrieve directories from tape storage on Levante using packems
# Restores data archived with the archive.sh script
#
# Usage:
#   1. Edit the CONFIGURATION section below
#   2. Update the #SBATCH --account to your project account
#   3. Test with: ./retrieve.sh --dry-run
#   4. Submit with: sbatch retrieve.sh
#
#   Or run interactively (for small datasets):
#     ./retrieve.sh
#
# Requirements:
#   - packems module available on Levante
#   - Read access to archive location
#   - Write access to restore destination
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION - Edit these variables for your use case
# =============================================================================

# Your username
USERNAME="${USER}"

# Project account for archive paths
PROJECT="bb1469"

# Archive base directory (where data was archived to)
ARCHIVE_BASE="/arch/${PROJECT}/${USERNAME}/awiesm3-develop/SPIN2"

# Destination base directory for restored data
RESTORE_BASE="/work/${PROJECT}/${USERNAME}/runtime/awiesm3-develop/SPIN2_restored"

# Scratch directory where tar balls are staged
SCRATCH_BASE="/scratch/${USERNAME:0:1}/${USERNAME}/packems_staging"

# Space-separated list of subdirectories to retrieve (optional)
# Leave empty to retrieve the entire archived directory
DIRS=""

# =============================================================================
# END OF CONFIGURATION
# =============================================================================

# Print usage information
usage() {
    echo "Usage: ./retrieve.sh [OPTIONS]"
    echo ""
    echo "Retrieve directories from DKRZ tape storage using unpackems."
    echo "Restores data that was archived with archive.sh."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message and exit"
    echo "  -n, --dry-run Preview what would be retrieved without making changes"
    echo ""
    echo "Current configuration (edit script to change):"
    echo "  ARCHIVE_BASE:  $ARCHIVE_BASE"
    echo "  RESTORE_BASE:  $RESTORE_BASE"
    echo "  SCRATCH_BASE:  $SCRATCH_BASE"
    if [ -n "$DIRS" ]; then
        echo "  DIRS:          $DIRS"
    else
        echo "  DIRS:          (entire archive)"
    fi
    echo ""
    echo "Examples:"
    echo "  ./retrieve.sh --dry-run   # Preview retrieval operation"
    echo "  ./retrieve.sh             # Run retrieval interactively"
    echo "  sbatch retrieve.sh        # Submit as batch job"
    exit 0
}

# Parse command line arguments
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

module purge
module load packems

echo "========================================"
echo "Packems Retrieval Script"
echo "Date: $(date)"
echo "User: $USERNAME"
if [ "$DRY_RUN" = true ]; then
    echo "MODE: DRY RUN (no changes will be made)"
fi
echo "========================================"
echo ""
echo "Configuration:"
echo "  Archive:     $ARCHIVE_BASE"
echo "  Restore to:  $RESTORE_BASE"
echo "  Staging:     $SCRATCH_BASE"
if [ -n "$DIRS" ]; then
    echo "  Directories: $DIRS"
else
    echo "  Directories: (entire archive)"
fi
echo ""

# Create restore directory
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$RESTORE_BASE"
fi

# Retrieve function
do_retrieve() {
    local PACK_SOURCE="$1"
    local ARCHIVE_DIR="$2"
    local RESTORE_DEST="$3"
    local NAME="$4"
    
    echo ""
    echo "----------------------------------------"
    echo "Retrieving: $NAME"
    echo "Archive: $ARCHIVE_DIR"
    echo "Tar ball staging: $PACK_SOURCE"
    echo "Restore to: $RESTORE_DEST"
    echo "Started: $(date)"
    echo "----------------------------------------"
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run: unpackems -d $RESTORE_DEST $PACK_SOURCE"
        if [ -f "${PACK_SOURCE}/INDEX.txt" ]; then
            echo "[DRY RUN] INDEX.txt found, listing contents:"
            head -20 "${PACK_SOURCE}/INDEX.txt"
        else
            echo "[DRY RUN] Note: INDEX.txt not found at $PACK_SOURCE"
        fi
    else
        mkdir -p "$RESTORE_DEST"
        unpackems -d "$RESTORE_DEST" "$PACK_SOURCE"
    fi
    
    echo "Completed: $NAME at $(date)"
}

# Retrieve either subdirectories or entire archive
if [ -n "$DIRS" ]; then
    for dir in $DIRS; do
        do_retrieve "${SCRATCH_BASE}/${dir}" "${ARCHIVE_BASE}/${dir}" "${RESTORE_BASE}/${dir}" "$dir"
    done
else
    # Retrieve entire archive
    PREFIX=$(basename "$ARCHIVE_BASE")
    do_retrieve "${SCRATCH_BASE}/${PREFIX}" "$ARCHIVE_BASE" "$RESTORE_BASE" "$PREFIX"
fi

echo ""
echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo "Dry run complete - no changes were made"
else
    echo "Retrieval complete"
fi
echo "Date: $(date)"
echo "========================================"
echo ""
echo "Restored data location: $RESTORE_BASE"
