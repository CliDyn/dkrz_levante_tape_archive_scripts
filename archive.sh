#!/bin/bash
#SBATCH --job-name=archive_packems
#SBATCH --partition=shared
#SBATCH --account=ab0995
#SBATCH --time=48:00:00
#SBATCH --mem=32G
#SBATCH --output=archive_packems_%j.log
#SBATCH --error=archive_packems_%j.err

# =============================================================================
# Archive directories to tape storage on Levante using packems
# Uses packems to bundle many small files into ~100GB tar balls
#
# Usage:
#   1. Edit the CONFIGURATION section below
#   2. Update the #SBATCH --account to your project account
#   3. Test with: ./archive.sh --dry-run
#   4. Submit with: sbatch archive.sh
#
#   Or run interactively (for small datasets):
#     ./archive.sh
#
# Requirements:
#   - packems module available on Levante
#   - Write access to source, scratch, and archive destinations
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION - Edit these variables for your use case
# =============================================================================

# Your username (used for scratch directory)
USERNAME="${USER}"

# Project account for work and archive paths
PROJECT="bb1469"

# Source base directory containing subdirectories to archive
SOURCE_BASE="/work/${PROJECT}/${USERNAME}/runtime/awiesm3-develop/SPIN2"

# Destination base directory on tape archive
DEST_BASE="/arch/${PROJECT}/${USERNAME}/awiesm3-develop/SPIN2"

# Scratch directory for staging tar balls (should have enough space)
SCRATCH_BASE="/scratch/${USERNAME:0:1}/${USERNAME}/packems_staging"

# Space-separated list of subdirectories to archive (optional)
# Leave empty to archive the entire SOURCE_BASE directory
DIRS=""

# Packems settings: target and max tar ball size in GB
TAR_TARGET_GB=100
TAR_MAX_GB=110

# =============================================================================
# END OF CONFIGURATION
# =============================================================================

# Print usage information
usage() {
    echo "Usage: ./archive.sh [OPTIONS]"
    echo ""
    echo "Archive directories to DKRZ tape storage using packems."
    echo "Bundles many small files into large tar balls for efficient tape storage."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message and exit"
    echo "  -n, --dry-run Preview what would be archived without making changes"
    echo ""
    echo "Current configuration (edit script to change):"
    echo "  SOURCE_BASE:   $SOURCE_BASE"
    echo "  DEST_BASE:     $DEST_BASE"
    echo "  SCRATCH_BASE:  $SCRATCH_BASE"
    if [ -n "$DIRS" ]; then
        echo "  DIRS:          $DIRS"
    else
        echo "  DIRS:          (entire source directory)"
    fi
    echo "  TAR_TARGET_GB: $TAR_TARGET_GB"
    echo ""
    echo "Examples:"
    echo "  ./archive.sh --dry-run   # Preview archive operation"
    echo "  ./archive.sh             # Run archive interactively"
    echo "  sbatch archive.sh        # Submit as batch job"
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

# Validate configuration
validate_config() {
    local errors=0
    
    if [ ! -d "$SOURCE_BASE" ]; then
        echo "ERROR: Source base directory does not exist: $SOURCE_BASE"
        errors=$((errors + 1))
    fi
    
    # If DIRS specified, check at least one exists
    if [ -n "$DIRS" ]; then
        local found=0
        for dir in $DIRS; do
            if [ -d "${SOURCE_BASE}/${dir}" ]; then
                found=$((found + 1))
            fi
        done
        
        if [ $found -eq 0 ]; then
            echo "ERROR: None of the specified directories exist in $SOURCE_BASE"
            echo "       Directories specified: $DIRS"
            errors=$((errors + 1))
        fi
    fi
    
    return $errors
}

echo "========================================"
echo "Packems Archive Script"
echo "Using packems to bundle files into ~${TAR_TARGET_GB}GB tar balls"
echo "Date: $(date)"
echo "User: $USERNAME"
if [ "$DRY_RUN" = true ]; then
    echo "MODE: DRY RUN (no changes will be made)"
fi
echo "========================================"
echo ""
echo "Configuration:"
echo "  Source:      $SOURCE_BASE"
echo "  Archive:     $DEST_BASE"
echo "  Staging:     $SCRATCH_BASE"
if [ -n "$DIRS" ]; then
    echo "  Directories: $DIRS"
else
    echo "  Directories: (entire source directory)"
fi
echo "  Tar size:    ${TAR_TARGET_GB}GB (max ${TAR_MAX_GB}GB)"
echo ""

# Validate before proceeding
if ! validate_config; then
    echo ""
    echo "Please fix the configuration errors above and try again."
    exit 1
fi

# Create scratch directory for tar balls
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$SCRATCH_BASE"
fi

# Archive function
do_archive() {
    local SOURCE="$1"
    local PACK_DEST="$2"
    local ARCHIVE_DEST="$3"
    local PREFIX="$4"
    
    echo ""
    echo "----------------------------------------"
    echo "Archiving: $PREFIX"
    echo "Source: $SOURCE"
    echo "Tar ball staging: $PACK_DEST"
    echo "Archive destination: $ARCHIVE_DEST"
    echo "Started: $(date)"
    echo "----------------------------------------"
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run: packems -t $TAR_TARGET_GB -m $TAR_MAX_GB -d $PACK_DEST -S $ARCHIVE_DEST -o $PREFIX $SOURCE"
        if command -v du &> /dev/null; then
            echo "[DRY RUN] Source size: $(du -sh "$SOURCE" 2>/dev/null | cut -f1)"
        fi
    else
        mkdir -p "$PACK_DEST"
        packems \
            -t "$TAR_TARGET_GB" -m "$TAR_MAX_GB" \
            -d "$PACK_DEST" \
            -S "$ARCHIVE_DEST" \
            -o "$PREFIX" \
            "$SOURCE"
    fi
    
    echo "Completed: $PREFIX at $(date)"
}

# Archive either subdirectories or entire source
if [ -n "$DIRS" ]; then
    for dir in $DIRS; do
        SOURCE="${SOURCE_BASE}/${dir}"
        if [ -d "$SOURCE" ]; then
            do_archive "$SOURCE" "${SCRATCH_BASE}/${dir}" "${DEST_BASE}/${dir}" "$dir"
        else
            echo "WARNING: Directory not found, skipping: $SOURCE"
        fi
    done
else
    # Archive entire SOURCE_BASE
    PREFIX=$(basename "$SOURCE_BASE")
    do_archive "$SOURCE_BASE" "${SCRATCH_BASE}/${PREFIX}" "$DEST_BASE" "$PREFIX"
fi

echo ""
echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo "Dry run complete - no changes were made"
else
    echo "Archive complete"
fi
echo "Date: $(date)"
echo "========================================"
echo ""
echo "Tar balls staged in: $SCRATCH_BASE"
echo "Archive location: $DEST_BASE"
echo "Each directory has an INDEX.txt listing packed files"
