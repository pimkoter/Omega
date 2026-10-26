#!/usr/bin/env bash
set -Eeuo pipefail

DIR=""
MOUNTPOINT="/tmp/nicenano"
FIRMWARE_ZIP="${1:-firmware.zip}"
DEVICE=""
MOUNTED=0
MOUNTPOINT_CREATED=0

sudo -v || {
    echo "Error: sudo authentication failed." >&2
    exit 1
}

cleanup() {
    local status=$?

    trap - EXIT INT TERM

    if [[ "$MOUNTED" == "1" ]]; then
        echo "Cleaning up: unmounting $MOUNTPOINT..."
        if sudo umount "$MOUNTPOINT"; then
            MOUNTED=0
        else
            echo "WARNING: Could not unmount $MOUNTPOINT." >&2
            echo "You may need to unmount it manually." >&2
        fi
    fi

    if [[ -n "$DIR" && -d "$DIR" ]]; then
        rm -rf -- "$DIR"
    fi

    if [[ "$MOUNTPOINT_CREATED" == "1" &&
          -d "$MOUNTPOINT" ]] &&
       ! mountpoint -q "$MOUNTPOINT"; then
        rmdir -- "$MOUNTPOINT" 2>/dev/null || true
    fi

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Check dependencies.
for cmd in unzip fzf lsblk mountpoint findmnt sudo; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command not found: $cmd" >&2
        exit 1
    fi
done

# Validate firmware archive.
if [[ ! -f "$FIRMWARE_ZIP" ]]; then
    echo "Error: Firmware archive not found: $FIRMWARE_ZIP" >&2
    echo "Usage: $0 [firmware.zip]" >&2
    exit 1
fi

# Prepare a unique temporary directory.
DIR=$(mktemp -d /tmp/temper.XXXXXX)

if [[ ! -d "$MOUNTPOINT" ]]; then
    mkdir -p -- "$MOUNTPOINT"
    MOUNTPOINT_CREATED=1
fi

if mountpoint -q "$MOUNTPOINT"; then
    echo "Error: $MOUNTPOINT is already mounted." >&2
    echo "Unmount it before running this script." >&2
    exit 1
fi

# Extract firmware before selecting a file.
echo "Extracting firmware from $FIRMWARE_ZIP..."
unzip -q "$FIRMWARE_ZIP" -d "$DIR"

# Find UF2 files recursively.
mapfile -t UF2_FILES < <(
    find "$DIR" -type f -iname '*.uf2' -print
)

if [[ ${#UF2_FILES[@]} -eq 0 ]]; then
    echo "Error: No .uf2 files found in the archive." >&2
    exit 1
fi

# Select firmware using fzf.
if ! UF2=$(
    printf '%s\n' "${UF2_FILES[@]}" |
        fzf --prompt="Select firmware > "
); then
    echo "Firmware selection cancelled."
    exit 0
fi

if [[ -z "$UF2" || ! -f "$UF2" ]]; then
    echo "Error: Selected firmware file is invalid." >&2
    exit 1
fi

echo
echo "Selected firmware: $(basename "$UF2")"
echo "Waiting for the Nice!Nano bootloader..."
echo "Put the controller into bootloader mode when ready."
echo "Press Ctrl+C to cancel."
echo

# Wait for a plausible bootloader partition.
# Explicit NICENANO labels are preferred, but an unlabeled
# 32 MB VFAT partition is also accepted as a candidate.
while true; do
    CANDIDATES=()

    while read -r name size fstype label type; do
        [[ "$type" == "disk" || "$type" == "part" ]] || continue

        # Accept either a whole USB disk (e.g. /dev/sda)
        # or a partition (e.g. /dev/sda1).
        [[ "$size" == "32M" || "$size" == "32.1M" ]] ||
            continue

        if [[ "${label:-}" == "NICENANO" ||
              "${label:-}" == "NICENANO2" ||
              "${fstype:-}" == "vfat" ]]; then
            CANDIDATES+=(
                "$name"$'\t'"$size"$'\t'"${fstype:-unknown}"$'\t'"${label:-no label}"$'\t'"$type"
            )
        fi
    done < <(
        lsblk -rpn -o PATH,SIZE,FSTYPE,LABEL,TYPE
    )

    if [[ ${#CANDIDATES[@]} -gt 0 ]]; then
        SELECTED=$(
            printf '%s\n' "${CANDIDATES[@]}" |
                fzf --prompt="Select bootloader device > " \
                    --header="DEVICE  SIZE  FSTYPE  LABEL  TYPE"
        ) || {
            echo "Device selection cancelled."
            exit 0
        }

        read -r DEVICE _ <<< "$SELECTED"

        if [[ ! -b "$DEVICE" ]]; then
            echo "Error: $DEVICE is no longer available." >&2
            exit 1
        fi

        echo
        echo "Firmware: $(basename "$UF2")"
        echo "Target:   $DEVICE"
        read -r -p "Flash this device? [y/N] " CONFIRM

        [[ "$CONFIRM" =~ ^[Yy]$ ]] || {
            echo "Installation cancelled."
            exit 0
        }

        echo "Mounting $DEVICE..."
        sudo mount "$DEVICE" "$MOUNTPOINT"
        MOUNTED=1

        if ! findmnt -rn -S "$DEVICE" \
                --target "$MOUNTPOINT" >/dev/null; then
            echo "Error: Unexpected device mounted." >&2
            exit 1
        fi

        echo "Copying firmware..."
        sudo cp -- "$UF2" "$MOUNTPOINT/"
        sync
        sudo umount "$MOUNTPOINT"
        MOUNTED=0

        echo "Firmware copied successfully."
        echo "Done!"
        exit 0
    fi

    sleep 1
done
