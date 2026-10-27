# DKRZ Levante Tape Archive Scripts

Scripts to archive data to the DKRZ tape archive on Levante. Since July 2026 the archive runs on Versity and is accessed with `atlas` (`module load tape`). StrongLink and `slk` are gone, and `packems` can no longer upload, so `packems` is only used to plan how files are split into tar balls.

## Overview

`archive.sh` archives one directory:
- Plans ~190 GB tar balls with `packems -N`
- Packs one tar ball at a time on scratch and checks the `tar` exit code
- Optionally compresses each tar ball with zstd (`--zstd`, writes `.tar.zst`)
- Uploads each tar ball with `atlas cp --checksum md5` while the next one is packed
- Optionally compares a local `md5sum` with the md5 stored in the archive (`--md5`)
- Optionally compares each tar ball against the source files with `tar --compare` (`--compare`)
- Optionally removes each tar ball from scratch once its checks passed (`--delete-scratch`), so scratch only holds a few tar balls at a time
- Sets the group of every archived file and of the folders it creates (`--group`, default the project in DEST), because `atlas cp` always uses your primary group
- Uploads `INDEX.txt` (which file is in which tar ball) and `<name>_meta.tar` (plan, logs, checksums)
- Never modifies the source

When the run used `--md5` and `--compare` and every tar ball passed all checks, it writes `delete_source.sh` to the state directory. Deleting the source is left to you.

## Scripts

### `archive.sh`
Packs, uploads and verifies a directory. Resubmitting the same command resumes after a failure or time limit; finished tar balls are skipped.

### `delete_source.py`
Called through the `delete_source.sh` that `archive.sh` writes. Dry run by default. It refuses to delete until every tar ball is written to tape (flag `a` in `atlas ls -l`), and only removes files whose type, size and mtime still match what was packed. Files that were never packed are listed and kept. Afterwards it removes every folder under the source that is empty, including folders that were empty from the start (those are not in the archive). Deleted files are listed in `deleted_<date>.log` in the state directory. File checks and deletions run 32 at a time (`--jobs N`); checking 340,000 files took 87 s.

### `retrieve.sh`
Still uses `slk` and does not work on Versity. Retrieve by searching `INDEX.txt`, then `atlas stage` and `atlas cp` the tar balls to `/scratch`. Unpack a `.tar.zst` with `zstd -dc X.tar.zst | tar -xf -` (add member paths to extract single files).

## Quick Start

```bash
# 1. Log in to the archive (valid for 30 days)
module load tape
atlas login

# 2. Preview the plan
./archive.sh --dry-run \
    /work/bb1469/a270092/runtime/lpjg-spinup-develop/lpj_spinup_HR_2000y \
    /hsm/arch/bb1469/a270092/lpjg-spinup-develop/lpj_spinup_HR_2000y

# 3. Archive (the state directory must exist for the Slurm log)
mkdir -p /work/bb1469/a270092/archive_state/lpj_spinup_HR_2000y
sbatch -o /work/bb1469/a270092/archive_state/lpj_spinup_HR_2000y/archive_%j.log \
    archive.sh --md5 --compare --delete-scratch --zstd \
    /work/bb1469/a270092/runtime/lpjg-spinup-develop/lpj_spinup_HR_2000y \
    /hsm/arch/bb1469/a270092/lpjg-spinup-develop/lpj_spinup_HR_2000y

# 4. Later, once the tar balls are on tape
/work/bb1469/a270092/archive_state/lpj_spinup_HR_2000y/delete_source.sh        # dry run
/work/bb1469/a270092/archive_state/lpj_spinup_HR_2000y/delete_source.sh --yes  # delete
```

Change `#SBATCH --account` if the job should not be charged to bb1469. Without `-o`, the Slurm log `archive_<jobid>.log` is written to the directory you submit from.

## Options

| Option | Description |
|--------|-------------|
| `--md5` | Compare `md5sum` of each local tar ball with the md5 stored in the archive |
| `--compare` | Compare each tar ball against the source files (`tar --compare`) |
| `--delete-scratch` | Remove each tar ball from scratch once all enabled checks passed (needs `--md5`) |
| `--window N` | Max finished tar balls waiting on scratch, default 3 |
| `--target-gb N` / `--max-gb N` | Tar ball size before compression, default 190 / 200 GB |
| `--zstd` | Compress tar balls with zstd, using all CPUs of the job |
| `--zstd-level N` | zstd level, default 3 (implies `--zstd`) |
| `--group NAME` | Group of the archived files and of folders the run creates, default the project in DEST (e.g. `bb1469`) |
| `--staging DIR` | Tar balls, default `/scratch/<u>/<user>/archive_staging/<name>` |
| `--state DIR` | Plan, logs, checksums, `delete_source.sh`, default `/work/<project>/<user>/archive_state/<name>` |
| `-n, --dry-run` | Only create and show the packing plan |

## Archive locations

| Path | Copies | Kept until |
|------|--------|------------|
| `/hsm/arch/<project>` | Hamburg only | project end + 1 year |
| `/hsm/double/<project>` | Hamburg and Garching | project end + 1 year |
| `/hsm/doku/<project>` | Hamburg and Garching | project end + 10 years, curated by DKRZ (Archive Long-Term quota) |

`/hsm/doku` cannot be written by users; ask support@dkrz.de to take data over from `/hsm/arch`.

## Notes

- Every archived file is accounted as at least 1 GB, which is why small files are packed
- `atlas cp` gives new files your primary group, ignoring the source file and the destination folder; `archive.sh` fixes this with `atlas chown` after each verified upload
- Measured on 2026-10-26: packing ~440 MB/s, `atlas cp` ~290 MB/s (one 61 GB tar ball)
- Archive quota counts the size on tape, and tar alone does not compress. LPJ-GUESS `.out` text files compress 10–100× with zstd level 3 (`ifs_input.out` ~100×, `landCoverFrac_monthly.out` ~20×, `gppLut_monthly.out` ~10×), so use `--zstd` for model output. Reading `/work` stays the limit, so compression costs no extra time and makes the upload much shorter
- On the `shared` partition Slurm assigns one CPU per ~0.9 GB of `--mem`, and CPUs are what is charged; the 16 GB in the script gives ~17 CPUs
- An upload ends in the archive's disk cache (flag `-o--v`); DKRZ writes it to tape later (flag `a`)
- Files in folders starting with `.` and Slurm output files are not written to tape when archived unpacked; inside a tar ball they are safe
- Documentation: https://docs.dkrz.de/doc/datastorage/versity/index.html

## License

GPL-3.0
