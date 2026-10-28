# DKRZ Levante Tape Archive Scripts

Scripts to archive data to the DKRZ tape archive (Versity) on Levante and get it back. The archive is accessed with `atlas` (`module load tape`); `packems` only plans how files are split into tar balls.

## Scripts

### `archive.sh`
Archives one directory:
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

Resubmitting the same command resumes after a failure or time limit; finished tar balls are skipped. When the run used `--md5` and `--compare` and every tar ball passed all checks, it writes `delete_source.sh` to the state directory. Deleting the source is left to you.

### `delete_source.py`
Called through the `delete_source.sh` that `archive.sh` writes. Dry run by default. It refuses to delete until every tar ball is written to tape (flag `a` in `atlas ls -l`), and only removes files whose type, size and mtime still match what was packed. Files that were never packed are listed and kept. Afterwards it removes every folder under the source that is empty, including folders that were empty from the start (those are not in the archive). Deleted files are listed in `deleted_<date>.log` in the state directory. File checks and deletions run in parallel (`--jobs N`, default 32).

### `retrieve.sh`
Gets files back from an archive folder written by `archive.sh` or by `packems -a`:
- Reads `INDEX.txt` and selects files (`--match REGEX` on the original path, default all)
- Stages only the tar balls that hold them from tape, then downloads them to scratch a few at a time
- Checks the md5 against the archive where one is stored
- Unpacks below `--to DIR` as `<source folder name>/...`, or to the original paths with `--restore`
- Never overwrites existing files, and removes each downloaded tar ball once unpacked

Resubmitting the same command resumes; unpacked tar balls are skipped.

## Quick Start

```bash
# 1. Log in to the archive (valid for 30 days)
module load tape
atlas login

# 2. Preview the plan
./archive.sh --dry-run /work/<project>/<user>/<experiment> /hsm/arch/<project>/<user>/<experiment>

# 3. Archive (the state directory must exist for the Slurm log)
ST=/work/<project>/<user>/archive_state/<experiment>
mkdir -p $ST
sbatch -o $ST/archive_%j.log archive.sh --md5 --compare --delete-scratch --zstd \
    /work/<project>/<user>/<experiment> /hsm/arch/<project>/<user>/<experiment>

# 4. Later, once the tar balls are on tape
$ST/delete_source.sh        # dry run
$ST/delete_source.sh --yes  # delete

# 5. Get files back
./retrieve.sh --dry-run --match '/restart/' /hsm/arch/<project>/<user>/<experiment>
sbatch retrieve.sh --match '/restart/' --to /work/<project>/<user>/restored \
    /hsm/arch/<project>/<user>/<experiment>
```

Change `#SBATCH --account` in both scripts to the project that should be charged. Without `-o`, the Slurm log is written to the directory you submit from.

## Options

### `archive.sh`

| Option | Description |
|--------|-------------|
| `--md5` | Compare `md5sum` of each local tar ball with the md5 stored in the archive |
| `--compare` | Compare each tar ball against the source files (`tar --compare`) |
| `--delete-scratch` | Remove each tar ball from scratch once all enabled checks passed (needs `--md5`) |
| `--zstd` | Compress tar balls with zstd, using all CPUs of the job |
| `--zstd-level N` | zstd level, default 3 (implies `--zstd`) |
| `--window N` | Max finished tar balls waiting on scratch, default 3 |
| `--target-gb N` / `--max-gb N` | Tar ball size before compression, default 190 / 200 GB |
| `--group NAME` | Group of the archived files and of folders the run creates, default the project in DEST |
| `--staging DIR` | Tar balls, default `/scratch/<u>/<user>/archive_staging/<name>` |
| `--state DIR` | Plan, logs, checksums, `delete_source.sh`, default `/work/<project>/<user>/archive_state/<name>` |
| `-n, --dry-run` | Only create and show the packing plan |

### `retrieve.sh`

| Option | Description |
|--------|-------------|
| `--match REGEX` | Only files whose original path matches (Python regex, repeatable) |
| `--to DIR` | Unpack below DIR, default `/scratch/<u>/<user>/retrieve/<name>` |
| `--restore` | Unpack to the original paths instead |
| `--staging DIR` | Downloaded tar balls, default `/scratch/<u>/<user>/retrieve_staging/<name>` |
| `--window N` | Tar balls downloaded ahead of unpacking, default 3 |
| `--keep-tars` | Keep the downloaded tar balls |
| `-n, --dry-run` | Only show which files and tar balls would be fetched |

## Archive locations

| Path | Copies | Kept until |
|------|--------|------------|
| `/hsm/arch/<project>` | Hamburg only | project end + 1 year |
| `/hsm/double/<project>` | Hamburg and Garching | project end + 1 year |
| `/hsm/doku/<project>` | Hamburg and Garching | project end + 10 years, curated by DKRZ (Archive Long-Term quota) |

`/hsm/doku` cannot be written by users; ask support@dkrz.de to take data over from `/hsm/arch`.

## Notes

- Every archived file is accounted as at least 1 GB, which is why small files are packed
- Quota counts the size on tape, and tar alone does not compress; use `--zstd` for model output
- `atlas cp` gives new files your primary group, ignoring the source file and the destination folder; `archive.sh` fixes this with `atlas chown`
- An upload first lands in the archive's disk cache (flag `-o--v`); DKRZ writes it to tape later (flag `a`)
- Files on tape only must be staged (`atlas stage`) before `atlas cp` can read them; a tape recall takes minutes even for small files
- Files in folders starting with `.` and Slurm output files are not written to tape when archived unpacked; inside a tar ball they are safe
- On the `shared` partition Slurm assigns one CPU per ~0.9 GB of `--mem`, and CPUs are what is charged
- Documentation: https://docs.dkrz.de/doc/datastorage/versity/index.html

## License

GPL-3.0
