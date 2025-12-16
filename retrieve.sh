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

# Space-separated list of subdirectories to retrieve
DIRS="run_19900101-19991231 log scripts"

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
    echo "  DIRS:          $DIRS"
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
echo "  Directories: $DIRS"
echo ""

# Create restore directory
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$RESTORE_BASE"
fi

for dir in $DIRS; do
    PACK_SOURCE="${SCRATCH_BASE}/${dir}"
    ARCHIVE_DIR="${ARCHIVE_BASE}/${dir}"
    RESTORE_DEST="${RESTORE_BASE}/${dir}"
    
    echo ""
    echo "----------------------------------------"
    echo "Retrieving: $dir"
    echo "Archive: $ARCHIVE_DIR"
    echo "Tar ball staging: $PACK_SOURCE"
    echo "Restore to: $RESTORE_DEST"
    echo "Started: $(date)"
    echo "----------------------------------------"
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run: unpackems -d $RESTORE_DEST $PACK_SOURCE"
        # Check if INDEX.txt exists
        if [ -f "${PACK_SOURCE}/INDEX.txt" ]; then
            echo "[DRY RUN] INDEX.txt found, listing contents:"
            head -20 "${PACK_SOURCE}/INDEX.txt"
        else
            echo "[DRY RUN] Note: INDEX.txt not found at $PACK_SOURCE"
        fi
    else
        mkdir -p "$RESTORE_DEST"
        
        # Unpack tar balls to restore destination
        # -d: destination directory for unpacked files
        unpackems -d "$RESTORE_DEST" "$PACK_SOURCE"
    fi
    
    echo "Completed: $dir at $(date)"
done

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
