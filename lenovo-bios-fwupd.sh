#!/usr/bin/env bash
#
# lenovo-bios-fwupd.sh
# Version 1.0
# Nadim Kobeissi -- https://github.com/nadimkobeissi/lenovo-bios-fwupd
#
# Converts a Lenovo Windows BIOS update .exe (Insyde H2OFFT based) into a
# fwupd-compatible .cab file that can be installed from Linux.
#
# Usage:
#   ./lenovo-bios-fwupd.sh <bios_update.exe>
#
# Requirements: 7z, gcab, fwupdmgr, fwupdtool, openssl
#
# IMPORTANT: Ensure AC power is connected and battery is above 30% before
# installing. Do NOT interrupt the reboot after installation.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
EXE="${1:-}"

if [[ "$EXE" == "--help" || "$EXE" == "-h" ]]; then
    echo "Usage: $0 <bios_update.exe>"
    echo ""
    echo "Converts a Lenovo Windows BIOS .exe into a fwupd .cab file."
    exit 0
fi

[[ -n "$EXE" ]] || die "Usage: $0 <bios_update.exe>"
[[ -f "$EXE" ]] || die "File not found: $EXE"

# --------------------------------------------------------------------------- #
# Dependency checks
# --------------------------------------------------------------------------- #
for cmd in 7z gcab fwupdmgr fwupdtool; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is required but not found. Please install it."
done

# --------------------------------------------------------------------------- #
# Set up working directory
# --------------------------------------------------------------------------- #
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Extracting $EXE ..."
7z x -o"$WORK/extracted" "$EXE" -bso0 -bsp0

# --------------------------------------------------------------------------- #
# Locate the .fd (or .rom) firmware file
# --------------------------------------------------------------------------- #
FD_FILE=$(find "$WORK/extracted" -maxdepth 1 \( -iname '*.fd' -o -iname '*.rom' \) | head -1)
[[ -n "$FD_FILE" ]] || die "No .fd or .rom firmware file found in the archive."
FD_BASENAME=$(basename "$FD_FILE")
echo "==> Found firmware: $FD_BASENAME"

# --------------------------------------------------------------------------- #
# Read the BIOS version string from the .fd filename
#   Lenovo convention: WinQ7CN45WW.fd -> version string is Q7CN45WW
# --------------------------------------------------------------------------- #
case "${FD_BASENAME,,}" in
    *.rom) BIOS_VERSION=$(basename "${EXE^^}" .EXE) ;;  # .rom name is a platform code; use nucn17ww.exe -> NUCN17WW
    *)     BIOS_VERSION=$(echo "$FD_BASENAME" | sed -E 's/^Win//i; s/\.fd$//i') ;;
esac
echo "==> BIOS version string: $BIOS_VERSION"

# --------------------------------------------------------------------------- #
# Read the System Firmware GUID and current ESRT version from sysfs
#   ESRT entry with fw_type=1 is the system firmware.
# --------------------------------------------------------------------------- #
echo "==> Reading System Firmware info from ESRT ..."
FW_GUID=""
FW_CURRENT_VERSION=""

for entry in /sys/firmware/efi/esrt/entries/entry*; do
    fw_type=$(sudo cat "$entry/fw_type" 2>/dev/null) || continue
    if [[ "$fw_type" == "1" ]]; then
        FW_GUID=$(sudo cat "$entry/fw_class")
        FW_CURRENT_VERSION=$(sudo cat "$entry/fw_version")
        break
    fi
done

[[ -n "$FW_GUID" ]] || die "Could not find System Firmware in ESRT.
Is this a UEFI system with an EFI System Resource Table?"

echo "==> System Firmware GUID: $FW_GUID"
echo "==> Current firmware version (ESRT): $FW_CURRENT_VERSION"

# --------------------------------------------------------------------------- #
# Determine the version number to put in the .cab metadata
#
# We set it to current_version + 1 so fwupd treats this as an upgrade.
# The actual version validation is handled by the UEFI firmware itself
# during the capsule update.
# --------------------------------------------------------------------------- #
# Strip any non-numeric characters (fwupd sometimes returns formatted versions)
NUMERIC_VERSION=$(echo "$FW_CURRENT_VERSION" | tr -cd '0-9')
[[ -n "$NUMERIC_VERSION" ]] || die "Could not parse current firmware version: $FW_CURRENT_VERSION"
NEW_VERSION=$((NUMERIC_VERSION + 1))
echo "==> Metadata version for .cab: $NEW_VERSION"

# Match the device's version format (plain/number), else fwupd refuses the .cab
VERSION_FORMAT=$(fwupdmgr get-devices --json 2>/dev/null | python3 -c '
import json, sys
guid = sys.argv[1].lower()
for dev in json.load(sys.stdin).get("Devices", []):
    if guid in [g.lower() for g in dev.get("Guid", [])]:
        print(dev.get("VersionFormat", "plain")); break
' "$FW_GUID" 2>/dev/null || true)
VERSION_FORMAT=${VERSION_FORMAT:-plain}
echo "==> Version format: $VERSION_FORMAT"

# --------------------------------------------------------------------------- #
# Get system product name for the metainfo
# --------------------------------------------------------------------------- #
PRODUCT=$(cat /sys/class/dmi/id/product_family 2>/dev/null || echo "Lenovo Laptop")

# --------------------------------------------------------------------------- #
# Build metainfo XML
# --------------------------------------------------------------------------- #
cat > "$WORK/firmware.metainfo.xml" <<METAINFO
<?xml version="1.0" encoding="UTF-8"?>
<component type="firmware">
  <id>com.lenovo.$(cat /sys/class/dmi/id/product_sku 2>/dev/null || echo "unknown").firmware</id>
  <name>$PRODUCT System Firmware</name>
  <summary>Lenovo BIOS Update $BIOS_VERSION</summary>
  <developer_name>Lenovo</developer_name>
  <provides>
    <firmware type="flashed">$FW_GUID</firmware>
  </provides>
  <releases>
    <release version="$NEW_VERSION" date="$(date +%Y-%m-%d)">
      <description>
        <p>Lenovo BIOS update $BIOS_VERSION</p>
      </description>
    </release>
  </releases>
  <custom>
    <value key="LVFS::VersionFormat">$VERSION_FORMAT</value>
  </custom>
</component>
METAINFO

# --------------------------------------------------------------------------- #
# Copy the .fd file as firmware.bin (fwupd convention)
# --------------------------------------------------------------------------- #
cp "$FD_FILE" "$WORK/firmware.bin"

# --------------------------------------------------------------------------- #
# Build the .cab
# --------------------------------------------------------------------------- #
OUTPUT_DIR=$(dirname "$(realpath "$EXE")")
CAB_NAME="${BIOS_VERSION}.cab"
OUTPUT_CAB="${OUTPUT_DIR}/${CAB_NAME}"

# --------------------------------------------------------------------------- #
# Sign the .cab (firmware.jcat) so fwupd's OnlyTrusted can stay enabled (see README)
# --------------------------------------------------------------------------- #
SIGN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lenovo-bios-fwupd"
SIGN_CERT="${SIGN_CERT:-$SIGN_DIR/cert.pem}"
SIGN_KEY="${SIGN_KEY:-$SIGN_DIR/key.pem}"
TRUSTED_CERT=/etc/pki/fwupd/LOCAL-CA.pem

command -v openssl &>/dev/null || die "openssl is required to sign the .cab."
# fwupd rejects trust certs without a keyUsage extension (older versions of
# this script generated such certs), so keep the old pair aside and regenerate
if [[ -e "$SIGN_CERT" ]] && ! openssl x509 -in "$SIGN_CERT" -noout -ext keyUsage 2>/dev/null \
        | grep -q 'Digital Signature'; then
    echo "==> $SIGN_CERT has no keyUsage; moving it to .old and regenerating"
    mv "$SIGN_CERT" "$SIGN_CERT.old"
    [[ -e "$SIGN_KEY" ]] && mv "$SIGN_KEY" "$SIGN_KEY.old"
fi
if [[ ! -e "$SIGN_CERT" && ! -e "$SIGN_KEY" ]]; then
    echo "==> Generating local signing key in $(dirname "$SIGN_KEY")"
    mkdir -p "$(dirname "$SIGN_CERT")" "$(dirname "$SIGN_KEY")"
    (umask 077 && openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
        -keyout "$SIGN_KEY" -out "$SIGN_CERT" \
        -subj "/CN=$USER local firmware signing" \
        -addext "keyUsage=critical,digitalSignature,keyCertSign" 2>/dev/null)
fi
if ! sudo cmp -s "$SIGN_CERT" "$TRUSTED_CERT"; then
    echo "==> Trusting $SIGN_CERT in fwupd ($TRUSTED_CERT)"
    sudo install -Dm644 "$SIGN_CERT" "$TRUSTED_CERT"
    sudo systemctl restart fwupd
fi

(cd "$WORK" && gcab --create "$OUTPUT_CAB" firmware.metainfo.xml firmware.bin)
# fwupd >= 2.0 only reads firmware.jcat; detached .p7b files are ignored
fwupdtool firmware-sign "$OUTPUT_CAB" "$SIGN_CERT" "$SIGN_KEY" \
    || die "fwupdtool firmware-sign failed."
echo "==> Signed with $SIGN_CERT"
echo "==> Created: $OUTPUT_CAB"

echo ""
echo "To install the update, run:"
echo "  sudo fwupdmgr install $OUTPUT_CAB --allow-reinstall --no-reboot-check"
echo ""
echo "Then reboot. The UEFI firmware will apply the capsule during boot."
echo "Ensure AC power is connected and battery is above 30%."
