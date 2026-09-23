
#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <firmware.uf2>"
    exit 1
fi

UF2="$1"

if [ ! -f "$UF2" ]; then
    echo "Firmware not found: $UF2"
    exit 1
fi

echo "Looking for Nice!Nano bootloader..."

DEVICE=""

while read -r name size fstype label; do
    if [[ "$size" == "32M" || "$size" == "32.1M" ]] &&
       [[ "$fstype" == "vfat" || "$label" == "NICENANO" || "$label" == "NICENANO2" ]]; then
        DEVICE="/dev/$name"
        break
    fi
done < <(
    lsblk -rno NAME,SIZE,FSTYPE,LABEL
)

if [ -z "$DEVICE" ]; then
    echo
    echo "Nice!Nano bootloader not found."
    echo "Double-tap RESET on the keyboard half and try again."
    echo
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
    exit 1
fi

echo "Found: $DEVICE"

MOUNTPOINT="/tmp/nicenano"

sudo mkdir -p "$MOUNTPOINT"

if ! mountpoint -q "$MOUNTPOINT"; then
    echo "Mounting $DEVICE..."
    sudo mount "$DEVICE" "$MOUNTPOINT"
fi

echo "Flashing $UF2..."

sudo cp "$UF2" "$MOUNTPOINT/"
sync

echo "Firmware copied successfully."

sudo umount "$MOUNTPOINT"

rm $UF2
echo "Done."
