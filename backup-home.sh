#!/usr/bin/env bash
#
# backup-home.sh — encrypted backup of $HOME (minus ~/Downloads) to a
# removable drive (SD card / USB stick).
#
# Pipeline:  tar  ->  zstd (or gzip)  ->  gpg --symmetric AES-256  ->  drive
#
# Each run produces one self-contained, passphrase-encrypted archive:
#   <dest>/home-backups/<host>-<user>-<YYYYmmdd-HHMMSS>.tar.zst.gpg
# plus a .sha256 checksum file. On FAT32 drives (4 GiB file limit) the
# archive is split into .part-000, .part-001, ... chunks automatically.
#
# Usage:
#   backup-home.sh backup  [-d DEST] [-k KEEP] [-x PATTERN]... [-p PASSFILE] [-V] [-n]
#   backup-home.sh restore ARCHIVE TARGET_DIR [-p PASSFILE]
#   backup-home.sh verify  ARCHIVE [-p PASSFILE]
#   backup-home.sh list    [-d DEST]
#
# Options:
#   -d DEST      Mount point of the SD card / USB drive. If omitted, drives
#                mounted under /media/$USER or /run/media/$USER are offered.
#   -k KEEP      Keep only the newest KEEP backups on the drive (default: keep all).
#   -x PATTERN   Extra path to exclude, relative to $HOME (repeatable),
#                e.g. -x .cache -x .local/share/Trash
#   -p PASSFILE  Read the passphrase from a file (chmod 600) for unattended
#                runs. Otherwise you are prompted.
#   -V           Verify the archive after writing (decrypt + list contents).
#   -n           Dry run: show what would happen, write nothing.
#   -h           Help.
#
# Restore example:
#   backup-home.sh restore /media/me/USB/home-backups/host-me-20261010-120000.tar.zst.gpg ~/restored
#
# Manual restore without this script (single file):
#   gpg -d ARCHIVE.tar.zst.gpg | zstd -d | tar -xf - -C TARGET_DIR
# (split archives: cat ARCHIVE.tar.zst.gpg.part-* | gpg -d | zstd -d | tar -xf - -C TARGET_DIR)

set -euo pipefail
umask 077

readonly SCRIPT_NAME=${0##*/}
readonly BACKUP_SUBDIR="home-backups"
readonly SPLIT_SIZE="3900M"          # safely under FAT32's 4 GiB limit
readonly MIN_PASS_LEN=12

DEST=""
KEEP=0
PASSFILE=""
VERIFY=0
DRY_RUN=0
EXCLUDES=("Downloads")

# ---------------------------------------------------------------- helpers ---

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

usage() { sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

need() { command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found. Install it and retry."; }

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

# Compression: prefer zstd (fast, good ratio), fall back to gzip.
if command -v zstd >/dev/null 2>&1; then
    COMPRESS=(zstd -T0 -6 -q -c); DECOMPRESS=(zstd -d -q -c); EXT="tar.zst"
else
    COMPRESS=(gzip -6 -c);        DECOMPRESS=(gzip -d -c);     EXT="tar.gz"
fi

decompress_for() {
    # Pick the decompressor from the archive name, not from what's installed now.
    case "$1" in
        *.tar.zst.gpg*) need zstd; DECOMPRESS=(zstd -d -q -c) ;;
        *.tar.gz.gpg*)  DECOMPRESS=(gzip -d -c) ;;
        *) die "Unrecognised archive name: $1" ;;
    esac
}

# Passphrase is held in a variable and handed to gpg through a process
# substitution, so it never appears on a command line or in `ps`.
PASSPHRASE=""
get_passphrase() {
    local confirm="${1:-0}"
    if [[ -n $PASSFILE ]]; then
        [[ -r $PASSFILE ]] || die "Cannot read passphrase file: $PASSFILE"
        local perms; perms=$(stat -c '%a' "$PASSFILE")
        [[ $perms =~ ^[0-7]00$ ]] || warn "Passphrase file $PASSFILE has mode $perms; use chmod 600."
        IFS= read -r PASSPHRASE <"$PASSFILE" || true
        [[ -n $PASSPHRASE ]] || die "Passphrase file is empty."
        return
    fi
    [[ -t 0 ]] || die "No terminal for a passphrase prompt; use -p PASSFILE."
    local again
    IFS= read -rsp "Encryption passphrase: " PASSPHRASE; echo >&2
    [[ -n $PASSPHRASE ]] || die "Empty passphrase."
    if (( confirm )); then
        (( ${#PASSPHRASE} >= MIN_PASS_LEN )) || die "Use a passphrase of at least $MIN_PASS_LEN characters."
        IFS= read -rsp "Confirm passphrase:    " again; echo >&2
        [[ $PASSPHRASE == "$again" ]] || die "Passphrases do not match."
    fi
}

gpg_encrypt() {
    gpg --batch --quiet --yes --no-symkey-cache --pinentry-mode loopback \
        --passphrase-file <(printf '%s' "$PASSPHRASE") \
        --symmetric --cipher-algo AES256 --compress-algo none \
        --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712 \
        --output -
}

gpg_decrypt() {
    gpg --batch --quiet --yes --no-symkey-cache --pinentry-mode loopback \
        --passphrase-file <(printf '%s' "$PASSPHRASE") \
        --decrypt
}

# Stream an archive (single file or split parts) to stdout.
read_archive() {
    local a="$1"
    if [[ -f $a ]]; then
        cat -- "$a"
    elif compgen -G "${a}.part-*" >/dev/null; then
        cat -- "${a}".part-*
    else
        die "Archive not found: $a"
    fi
}

# Normalise "foo.tar.zst.gpg.part-000" or "foo.tar.zst.gpg.sha256" to the base name.
archive_base() { local a="${1%.sha256}"; echo "${a%.part-*}"; }

# Offer drives automounted by the desktop under /media/$USER or /run/media/$USER.
pick_destination() {
    local -a mounts=()
    local m
    while IFS= read -r m; do
        [[ -n $m ]] && mounts+=("$m")
    done < <(findmnt -rn -o TARGET | grep -E "^(/media|/run/media)/${USER}/" || true)

    (( ${#mounts[@]} )) || die "No removable drive found under /media/$USER or /run/media/$USER. Insert/mount one, or pass -d."

    if (( ${#mounts[@]} == 1 )); then
        DEST="${mounts[0]}"
        log "Using the only removable drive found: $DEST"
        return
    fi
    [[ -t 0 ]] || die "Several drives mounted; choose one with -d."
    echo "Mounted removable drives:" >&2
    local i
    for i in "${!mounts[@]}"; do
        printf '  %d) %s  (%s free, %s)\n' "$((i + 1))" "${mounts[i]}" \
            "$(df -h --output=avail "${mounts[i]}" | tail -1 | tr -d ' ')" \
            "$(findmnt -rn -o FSTYPE --target "${mounts[i]}")" >&2
    done
    local choice
    read -rp "Choose drive [1-${#mounts[@]}]: " choice
    [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#mounts[@]} )) || die "Invalid choice."
    DEST="${mounts[choice - 1]}"
}

check_destination() {
    [[ -d $DEST ]] || die "Destination does not exist: $DEST"
    DEST=$(realpath -- "$DEST")
    mountpoint -q -- "$DEST" || warn "$DEST is not itself a mount point. Is the drive actually mounted?"
    local home_real; home_real=$(realpath -- "$HOME")
    [[ $DEST/ == "$home_real"/* ]] && die "Destination $DEST is inside \$HOME; refusing (the backup would include itself)."
    [[ -w $DEST ]] || die "Destination is not writable: $DEST"
}

# ----------------------------------------------------------------- backup ---

do_backup() {
    need tar; need gpg; need split; need sha256sum; need findmnt
    [[ -n $DEST ]] || pick_destination
    check_destination

    local outdir="$DEST/$BACKUP_SUBDIR"
    local stamp; stamp=$(date '+%Y%m%d-%H%M%S')
    local name="$(hostname -s)-${USER}-${stamp}.${EXT}.gpg"
    local out="$outdir/$name"
    local fstype; fstype=$(findmnt -rn -o FSTYPE --target "$DEST")

    local split_output=0
    case "$fstype" in vfat|msdos|fat|fat32) split_output=1 ;; esac

    # Build tar exclude list (anchored to the top of $HOME).
    local -a tar_excl=(--anchored)
    local e
    for e in "${EXCLUDES[@]}"; do
        e="${e#./}"; e="${e%/}"
        tar_excl+=(--exclude="./$e")
    done

    log "Source:       $HOME"
    log "Excluding:    ${EXCLUDES[*]}"
    log "Destination:  $out$( (( split_output )) && echo '.part-NNN')"
    log "Filesystem:   $fstype$( (( split_output )) && echo " (FAT: splitting into $SPLIT_SIZE chunks)")"

    # Space estimate (uncompressed size of source vs free space on drive).
    local -a du_excl=()
    for e in "${EXCLUDES[@]}"; do du_excl+=(--exclude="$HOME/${e%/}"); done
    local src_bytes avail_bytes
    src_bytes=$(du -sb "${du_excl[@]}" -- "$HOME" 2>/dev/null | cut -f1 || echo 0)
    avail_bytes=$(df -B1 --output=avail "$DEST" | tail -1 | tr -d ' ')
    log "Source size:  $(human "$src_bytes") (before compression)"
    log "Free on drive: $(human "$avail_bytes")"
    if (( src_bytes > avail_bytes )); then
        warn "Source is larger than the free space. Compression may make it fit, but it may not."
        if [[ -t 0 ]] && (( ! DRY_RUN )); then
            local ans; read -rp "Continue anyway? [y/N] " ans
            [[ $ans =~ ^[Yy]$ ]] || die "Aborted."
        fi
    fi

    if (( DRY_RUN )); then
        log "Dry run: nothing written."
        return
    fi

    mkdir -p -- "$outdir"
    exec 9>"$outdir/.lock"
    flock -n 9 || die "Another backup to this drive is already running."

    get_passphrase 1

    local tmp="$outdir/.${name}.partial"
    rm -f -- "$tmp" "$tmp".part-*
    # Clean up partial output if we're interrupted or fail.
    trap 'rm -f -- "$tmp" "$tmp".part-*; die "Interrupted; partial output removed."' INT TERM
    trap 'rc=$?; (( rc )) && rm -f -- "$tmp" "$tmp".part-*' EXIT

    log "Creating encrypted archive (this can take a while)..."
    local start=$SECONDS
    set +o pipefail
    if (( split_output )); then
        tar -C "$HOME" -cf - --warning=no-file-changed --warning=no-file-ignored \
            --ignore-failed-read "${tar_excl[@]}" . \
            | "${COMPRESS[@]}" | gpg_encrypt \
            | split -b "$SPLIT_SIZE" -d -a 3 - "$tmp.part-"
    else
        tar -C "$HOME" -cf - --warning=no-file-changed --warning=no-file-ignored \
            --ignore-failed-read "${tar_excl[@]}" . \
            | "${COMPRESS[@]}" | gpg_encrypt >"$tmp"
    fi
    local -a rcs=("${PIPESTATUS[@]}")
    set -o pipefail

    # tar exit 1 = "some files changed while being read" -> warning, not failure.
    (( rcs[0] <= 1 )) || die "tar failed (exit ${rcs[0]})."
    (( rcs[0] == 1 )) && warn "Some files changed during the backup; they may be inconsistent in the archive."
    (( rcs[1] == 0 )) || die "Compression failed (exit ${rcs[1]})."
    (( rcs[2] == 0 )) || die "Encryption failed (exit ${rcs[2]})."
    (( ${#rcs[@]} < 4 || rcs[3] == 0 )) || die "Writing to drive failed (exit ${rcs[3]}). Is it full?"

    # Move into place and write checksums.
    local -a final_files=()
    if (( split_output )); then
        local p
        for p in "$tmp".part-*; do
            mv -- "$p" "$out.part-${p##*.part-}"
            final_files+=("$out.part-${p##*.part-}")
        done
    else
        mv -- "$tmp" "$out"
        final_files=("$out")
    fi
    (cd -- "$outdir" && sha256sum -- "${final_files[@]##*/}") >"$out.sha256"

    log "Flushing writes to the drive..."
    sync -f -- "$out.sha256" 2>/dev/null || sync

    local size; size=$(du -cb -- "${final_files[@]}" | tail -1 | cut -f1)
    log "Backup written: $(human "$size") in $(( SECONDS - start ))s"

    if (( VERIFY )); then
        verify_archive "$out"
    fi

    (( KEEP > 0 )) && prune_old "$outdir"

    trap - INT TERM EXIT
    log "Done. Safe to eject after the drive's light stops blinking:  udisksctl unmount -b \$(findmnt -n -o SOURCE --target '$DEST')"
}

# -------------------------------------------------------------- retention ---

list_backups() {
    # Prints base archive paths, oldest first.
    local outdir="$1"
    [[ -d $outdir ]] || return 0
    find "$outdir" -maxdepth 1 -type f -name '*.gpg.sha256' -printf '%f\n' \
        | sort | sed "s|^|$outdir/|; s|\.sha256$||"
}

prune_old() {
    local outdir="$1"
    local -a all=()
    mapfile -t all < <(list_backups "$outdir")
    local n=${#all[@]}
    (( n > KEEP )) || return 0
    local i
    for (( i = 0; i < n - KEEP; i++ )); do
        log "Removing old backup: ${all[i]##*/}"
        rm -f -- "${all[i]}" "${all[i]}".part-* "${all[i]}.sha256"
    done
}

# ------------------------------------------------------- verify / restore ---

check_sha() {
    local base="$1"
    if [[ -f $base.sha256 ]]; then
        log "Checking SHA-256 checksums..."
        (cd -- "$(dirname -- "$base")" && sha256sum --quiet -c -- "${base##*/}.sha256") \
            || die "Checksum mismatch: the archive is corrupted."
    else
        warn "No checksum file found; skipping checksum check."
    fi
}

verify_archive() {
    local base; base=$(archive_base "$1")
    decompress_for "$base"
    check_sha "$base"
    [[ -n $PASSPHRASE ]] || get_passphrase 0
    log "Decrypting and reading the archive to verify it..."
    # PIPESTATUS doesn't survive a command substitution, so print it from inside.
    local out count
    out=$(set +o pipefail
          read_archive "$base" | gpg_decrypt | "${DECOMPRESS[@]}" | tar -tf - | wc -l
          echo "${PIPESTATUS[*]}")
    count=$(head -1 <<<"$out")
    local -a rcs
    read -ra rcs <<<"$(tail -1 <<<"$out")"
    (( rcs[1] == 0 )) || die "Decryption failed (wrong passphrase or corrupted archive)."
    (( rcs[2] == 0 && rcs[3] == 0 )) || die "Archive is corrupted (decompress=${rcs[2]}, tar=${rcs[3]})."
    log "Verified OK: $count entries."
}

do_restore() {
    local base; base=$(archive_base "$1")
    local target="$2"
    decompress_for "$base"
    need gpg; need tar
    mkdir -p -- "$target"
    target=$(realpath -- "$target")
    if [[ -n $(ls -A -- "$target") ]]; then
        warn "$target is not empty; files with the same names will be overwritten."
        [[ -t 0 ]] && { local ans; read -rp "Continue? [y/N] " ans; [[ $ans =~ ^[Yy]$ ]] || die "Aborted."; }
    fi
    check_sha "$base"
    get_passphrase 0
    log "Restoring into $target ..."
    set +o pipefail
    read_archive "$base" | gpg_decrypt | "${DECOMPRESS[@]}" | tar -xpf - -C "$target"
    local -a rcs=("${PIPESTATUS[@]}")
    set -o pipefail
    (( rcs[1] == 0 )) || die "Decryption failed (wrong passphrase or corrupted archive)."
    (( rcs[2] == 0 && rcs[3] == 0 )) || die "Restore failed (decompress=${rcs[2]}, tar=${rcs[3]})."
    log "Restore complete."
}

do_list() {
    [[ -n $DEST ]] || pick_destination
    check_destination
    local outdir="$DEST/$BACKUP_SUBDIR" b
    local -a all=()
    mapfile -t all < <(list_backups "$outdir")
    (( ${#all[@]} )) || { log "No backups in $outdir"; return; }
    for b in "${all[@]}"; do
        printf '%s  %s\n' "$(du -cb -- "$b" "$b".part-* 2>/dev/null | tail -1 | cut -f1 | numfmt --to=iec --suffix=B)" "$b"
    done
}

# ------------------------------------------------------------------- main ---

CMD="${1:-}"
case "$CMD" in
    backup|restore|verify|list) shift ;;
    -h|--help|help) usage 0 ;;
    "") usage 1 ;;
    -*) CMD=backup ;;                      # allow `backup-home.sh -d /media/...`
    *) die "Unknown command '$CMD'. Try: $SCRIPT_NAME -h" ;;
esac

POSITIONAL=()
while (( $# )); do
    case "$1" in
        -d) DEST="${2:?-d needs a path}"; shift 2 ;;
        -k) KEEP="${2:?-k needs a number}"; [[ $KEEP =~ ^[0-9]+$ ]] || die "-k must be a number"; shift 2 ;;
        -x) EXCLUDES+=("${2:?-x needs a path}"); shift 2 ;;
        -p) PASSFILE="${2:?-p needs a file}"; shift 2 ;;
        -V) VERIFY=1; shift ;;
        -n) DRY_RUN=1; shift ;;
        -h|--help) usage 0 ;;
        -*) die "Unknown option $1" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

case "$CMD" in
    backup)  do_backup ;;
    list)    do_list ;;
    verify)  (( ${#POSITIONAL[@]} == 1 )) || die "Usage: $SCRIPT_NAME verify ARCHIVE"; verify_archive "${POSITIONAL[0]}" ;;
    restore) (( ${#POSITIONAL[@]} == 2 )) || die "Usage: $SCRIPT_NAME restore ARCHIVE TARGET_DIR"; do_restore "${POSITIONAL[@]}" ;;
esac
