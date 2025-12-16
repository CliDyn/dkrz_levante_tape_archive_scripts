# DKRZ Levante Tape Archive Scripts

Scripts to archive and retrieve data from DKRZ tape storage on Levante using `packems`.

## Overview

These scripts simplify archiving large datasets to tape storage by:
- Bundling many small files into ~100GB tar balls using `packems`
- Providing configurable paths and settings
- Supporting dry-run mode to preview operations
- Handling batch archiving of multiple directories

## Scripts

### `archive.sh`
Archives directories from work filesystem to tape storage.

### `retrieve.sh`
Retrieves archived data from tape storage back to work filesystem.

## Requirements

- Access to DKRZ Levante HPC system
- `packems` module (loaded automatically by scripts)
- Write access to source, scratch, and archive destinations

## Quick Start

### 1. Configure the script

Edit the `CONFIGURATION` section in each script:

```bash
# Your username (auto-detected)
USERNAME="${USER}"

# Project account for paths
PROJECT="ab0995"

# Source directory containing subdirectories to archive
# Example: /work/ab0995/k204221/runtime/my_experiment
SOURCE_BASE="/work/${PROJECT}/${USERNAME}/runtime/my_experiment"

# Destination on tape archive
# Example: /arch/ab0995/k204221/my_experiment
DEST_BASE="/arch/${PROJECT}/${USERNAME}/my_experiment"

# Scratch directory for staging tar balls
SCRATCH_BASE="/scratch/${USERNAME:0:1}/${USERNAME}/packems_staging"

# Subdirectories to archive (space-separated)
DIRS="outdata restart log"
```

### 2. Update SLURM account

Change the `#SBATCH --account` line to your project account.

### 3. Test with dry-run

```bash
# Preview what will be archived
./archive.sh --dry-run

# Preview what will be retrieved
./retrieve.sh --dry-run
```

### 4. Run the archive/retrieve

```bash
# Submit as batch job (recommended for large datasets)
sbatch archive.sh
sbatch retrieve.sh

# Or run interactively (for small datasets)
./archive.sh
./retrieve.sh
```

## Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message and current configuration |
| `-n, --dry-run` | Preview operations without making changes |

## Packems Settings

The scripts use these default `packems` settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `TAR_TARGET_GB` | 100 | Target tar ball size in GB |
| `TAR_MAX_GB` | 110 | Maximum tar ball size in GB |

Adjust these in the configuration section if needed.

## Output

- **Staging directory**: Contains tar balls and INDEX.txt files
- **INDEX.txt**: Lists all files packed in each tar ball (useful for finding specific files)
- **Archive location**: Final destination on tape storage

## Notes

- Archiving large datasets can take several hours
- The scratch directory needs sufficient space for staging tar balls
- Each archived directory gets its own INDEX.txt for tracking contents
- Use `--dry-run` to estimate sizes before archiving

## License

GPL-3.0
