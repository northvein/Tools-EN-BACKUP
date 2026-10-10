# Home-Backup

`backup-home.sh` makes an encrypted backup of your home directory (excluding `~/Downloads`) to an SD card or USB drive. It can also verify, list and restore those backups.

```
$HOME  ──tar──▶  zstd  ──▶  gpg (AES-256, passphrase)  ──▶  /media/$USER/<drive>/home-backups/
```

Each run creates a self-contained archive that only your passphrase can decrypt. You can restore it on any Linux machine that has `gpg` and `zstd` installed. You don't need this script to restore.

## Features

- **Encrypted at rest:** uses GnuPG symmetric AES-256 with a strengthened passphrase-to-key step (SHA-512, maximum iteration count). The archive is integrity-protected, so a wrong passphrase or tampering is detected.
- **Excludes `~/Downloads`** by default. Use `-x` to exclude more, such as `.cache` or the Trash.
- **Finds the drive automatically:** it picks up drives mounted under `/media/$USER` or `/run/media/$USER`, and asks you to choose if there are several.
- **Works on FAT32:** on `vfat` drives (most SD cards and USB sticks), the archive is split into parts of about 3.9 GB to stay under FAT32's 4 GiB file limit.
- **Writes safely:**
  - The archive is written under a temporary name and only renamed once it's complete. Partial output is deleted if the run fails or you press Ctrl-C.
  - A lock file stops two backups running at once on the same drive.
  - It refuses a destination inside `$HOME`, which would back up the backup.
  - It checks free space before starting.
- **SHA-256 checksums** for every archive (or every part), checked before verify and restore.
- **Optional verification** (`-V`): decrypts the new archive and reads it through after writing.
- **Retention** (`-k N`): keeps only the newest N backups on the drive.
- **Passphrase handling:** the passphrase never appears on the command line or in `ps`. It's typed and confirmed interactively, or read from a `chmod 600` file for unattended runs.

## Requirements

| Tool | Package (Debian/Ubuntu) | Notes |
|------|-------------------------|-------|
| `bash` ≥ 4.4 | `bash` | |
| `gpg` ≥ 2.1 | `gnupg` | |
| `tar`, `split`, `sha256sum`, `numfmt` | `tar`, `coreutils` | |
| `findmnt`, `flock` | `util-linux` | |
| `zstd` | `zstd` | Optional. Falls back to `gzip` (`.tar.gz.gpg`) if missing |

```bash
sudo apt install gnupg zstd
```

## Installation

```bash
chmod +x backup-home.sh
```

To run it from anywhere, you can also put it on your `PATH`:

```bash
ln -s "$PWD/backup-home.sh" ~/.local/bin/backup-home
```

## Usage

```
backup-home.sh backup  [-d DEST] [-k KEEP] [-x PATTERN]... [-p PASSFILE] [-V] [-n]
backup-home.sh restore ARCHIVE TARGET_DIR [-p PASSFILE]
backup-home.sh verify  ARCHIVE [-p PASSFILE]
backup-home.sh list    [-d DEST]
```

`backup` is the default command, so `backup-home.sh -d /media/$USER/USB` also works.

| Option | Meaning |
|--------|---------|
| `-d DEST` | Mount point of the drive. If you leave it out, the script detects mounted removable drives. |
| `-k KEEP` | Keep only the newest `KEEP` backups (deletes older ones after a successful run). The default keeps all. |
| `-x PATTERN` | Extra path to exclude, relative to `$HOME`. You can repeat it. |
| `-p PASSFILE` | Read the passphrase from a file instead of prompting. |
| `-V` | Verify the archive after writing. |
| `-n` | Dry run: shows the source size, free space and destination, and writes nothing. |
| `-h` | Help. |

### Examples

Back up to the only inserted drive, then verify it:

```bash
./backup-home.sh backup -V
```

Back up to a specific drive, skip caches and the Trash, and keep the last 5 backups:

```bash
./backup-home.sh backup -d /media/$USER/MYUSB -k 5 -x .cache -x .local/share/Trash -V
```

See what's on the drive:

```bash
./backup-home.sh list -d /media/$USER/MYUSB
```

Restore into a new folder:

```bash
./backup-home.sh restore /media/$USER/MYUSB/home-backups/myhost-me-20261010-120000.tar.zst.gpg ~/restored
```

For split archives, pass the base name (without `.part-NNN`) or any one of the part files. The script finds the rest.

Restore everything except Downloads straight back into your home directory, for example on a fresh install:

```bash
./backup-home.sh restore /media/$USER/MYUSB/home-backups/<archive>.tar.zst.gpg ~
```

Files with the same name are overwritten. The script warns you and asks before writing into a non-empty folder.

## Output on the drive

```
<drive>/home-backups/
├── myhost-me-20261010-120000.tar.zst.gpg          # the encrypted archive
├── myhost-me-20261010-120000.tar.zst.gpg.sha256   # checksum
├── myhost-me-20261011-120000.tar.zst.gpg.part-000 # split archive (FAT32 drives)
├── myhost-me-20261011-120000.tar.zst.gpg.part-001
└── myhost-me-20261011-120000.tar.zst.gpg.sha256
```

## Restoring without the script

You only need standard tools:

```bash
# Single file
gpg -d ARCHIVE.tar.zst.gpg | zstd -d | tar -xf - -C ~/restored

# Split archive
cat ARCHIVE.tar.zst.gpg.part-* | gpg -d | zstd -d | tar -xf - -C ~/restored

# Check integrity first (run inside the home-backups folder)
sha256sum -c ARCHIVE.tar.zst.gpg.sha256
```

## Unattended / scheduled backups

1. Create a passphrase file that only you can read. Keep it **off** the backup drive, and preferably outside `$HOME`. Any file in `$HOME` ends up inside the backup.

   ```bash
   install -m 600 /dev/null ~/.config/backup-home.pass   # then edit and add the passphrase
   ```

   > The passphrase file sits on your (ideally disk-encrypted) machine. Anyone who can read it can decrypt your backups, so only use this if the machine itself is secured.

2. Add a cron entry (`crontab -e`) that runs when the drive is normally plugged in:

   ```cron
   0 21 * * * /path/to/backup-home.sh backup -d /media/me/MYUSB -k 7 -x .cache -p ~/.config/backup-home.pass -V >> ~/.local/state/backup-home.log 2>&1
   ```

   Without `-d`, the run fails safely when no drive is mounted or when more than one drive is mounted.

## Security notes

- **Nobody can recover a forgotten passphrase,** including you. Store it in a password manager. Use a long passphrase; the minimum enforced length is 12 characters.
- File names, sizes and contents are all inside the encrypted archive. Only the archive file name (host, user, timestamp) and its total size are visible.
- The archive includes sensitive material from your home directory, such as `~/.ssh`, `~/.gnupg`, browser profiles and saved tokens. That's intended, because it makes the backup complete, so treat the passphrase accordingly.
- Physically separate copies are better: keep at least one backup drive away from the computer.
- Test a restore occasionally (`verify`, or a `restore` into a temporary folder). An untested backup isn't a backup.

## Limitations

- **Every run is a full backup**, with no incremental or deduplicated copies. For large home directories backed up often, consider [restic](https://restic.net/) or [borg](https://www.borgbackup.org/).
- Files changing while the backup runs (open databases, browser profiles in use) may be captured in an inconsistent state. The script warns when this happens. Close heavy applications first for the cleanest backup.
- Files you can't read (for example, owned by root) are skipped with a warning.
- Drive auto-detection only looks at desktop automount locations (`/media/$USER`, `/run/media/$USER`). Use `-d` for anything else.

## Ejecting the drive

When the script finishes, it flushes all writes to the drive. Then unmount it before you pull it out:

```bash
udisksctl unmount -b "$(findmnt -n -o SOURCE --target /media/$USER/MYUSB)"
```

You can also use the eject button in your file manager.
