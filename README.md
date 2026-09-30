# lenovo-bios-fwupd

_Install BIOS/UEFI firmware updates for modern Lenovo Legion laptops on Linux, without needing Windows!_

lenovo-bios-fwupd converts Lenovo Windows BIOS update `.exe` files (Insyde H2OFFT based) into fwupd-compatible `.cab` files that can be installed from Linux.

Many Lenovo laptops don't receive BIOS updates through [LVFS](https://fwupd.org/), so the only official update path is a Windows `.exe`. This script extracts the firmware from that `.exe`, reads your system's EFI System Resource Table (ESRT) to get the correct GUID, and packages everything into a `.cab` that `fwupdmgr` can install natively.

## Requirements

- `7z` (p7zip)
- `gcab`
- `fwupdmgr` (fwupd)
- `python3` (optional; used to match the device's version format, falls back to `plain`)
- `openssl` (optional; only needed to sign the `.cab`, see below)

## Downloading the BIOS update

1. Go to [Lenovo PC Support](https://pcsupport.lenovo.com/).
2. Find your laptop model (e.g. search for "Legion Pro 7 16IAX10H").
3. Navigate to **Drivers & Software** and filter by the **BIOS/UEFI** component. For example, for the Legion Pro 7 16IAX10H, [this](https://pcsupport.lenovo.com/fr/fr/products/laptops-and-netbooks/legion-series/legion-pro-7-16iax10h/downloads/driver-list/component?name=BIOS%2FUEFI&id=5AC6A815-321D-440E-8833-B07A93E0428C) is the direct link.
4. Download the latest BIOS update `.exe` file.

## Usage

```bash
./lenovo-bios-fwupd.sh <bios_update.exe>
```

The script will:

1. Extract the `.exe` archive with `7z`.
2. Locate the `.fd` (or `.rom`) firmware file inside.
3. Parse the BIOS version string from the filename (`.rom` payloads: from the `.exe` name).
4. Read your system's firmware GUID and current version from the ESRT.
5. Generate fwupd-compatible metainfo XML (version format taken from `fwupdmgr get-devices`).
6. Sign the payload, if a signing key is configured (see below).
7. Package everything into a `.cab` file.

Then install the resulting `.cab`:

```bash
sudo fwupdmgr install <version>.cab --allow-reinstall --no-reboot-check
```

Reboot to apply the update. The UEFI firmware will apply the capsule during boot.

**Important:** Ensure AC power is connected and battery is above 30% before installing. Do **not** interrupt the reboot after installation.

## Signing & Secure Boot

This script adds a third signature to the update pipeline alongside two existing vendor signatures.

| Layer | Signed by | Verified by |
| --- | --- | --- |
| Downloaded `.exe` | `CN=Lenovo` | Windows |
| `.fd` / `.rom` payload | `CN=Certificate_NU` | Lenovo platform firmware |
| `.cab` wrapper | Unsigned by default | `fwupd` (when `OnlyTrusted=true`) |

### Signature Verification

* **Authenticode cannot be reused:** Authenticode signs the `.exe` hash. Extracting the embedded `.fd` creates a new file that invalidates this signature. `fwupd` ignores Authenticode and verifies the `firmware.jcat` signatures inside the `.cab` against `/etc/pki/fwupd/`.
* **Payload signature is preserved:** The payload retains its Lenovo signature through extraction and repacking. Platform firmware validates this signature before flashing.
* **Checking payload certificates:** Subject CN values vary by platform. Inspect yours with:

```bash
7z x -oout bios_update.exe
python3 -c 'import struct,sys
f=open(sys.argv[1],"rb"); h=f.read(4096)
p=struct.unpack_from("<I",h,0x3c)[0]; o=p+24
b=o+(112 if struct.unpack_from("<H",h,o)[0]==0x20b else 96)
off,sz=struct.unpack_from("<II",h,b+32)
f.seek(off); sys.stdout.buffer.write(f.read(sz)[8:])' \
  "$(find out -maxdepth 1 \( -iname '*.fd' -o -iname '*.rom' \) | head -1)" \
  | openssl pkcs7 -inform DER -print_certs -noout
```

Output for a Legion Slim 5 16ARP9:

```
subject=CN=Certificate_NU
issuer=CN=Trust-Lenovo Certificate
```

This reads the PE certificate table straight out of the payload and prints the signer, using only `python3` and `openssl`. Do not use `osslsigncode verify` here: it chain-verifies against `/etc/ssl/certs/ca-certificates.crt`, and `CN=Trust-Lenovo Certificate` is a private root held only in your laptop's flash, so it reports `Signature verification: failed` on every machine regardless of whether the payload is intact. The `find` is needed because the payload filename varies in case between models.

### Option 1: Sign the `.cab` (Recommended, automatic)

The script handles this. On first run it generates a local key pair in `~/.config/lenovo-bios-fwupd/` (`key.pem` mode `600`), installs `cert.pem` as `/etc/pki/fwupd/LOCAL-CA.pem` via `sudo`, restarts `fwupd`, and signs the `.cab` with `fwupdtool firmware-sign`, which adds `firmware.jcat`. fwupd 2.x ignores detached `.p7b` files. Later runs reuse the key. The cert carries a `keyUsage` extension, because fwupd rejects trust certs without one; a cert made by an older version of this script is moved to `cert.pem.old` and regenerated automatically. No changes to `fwupd.conf` are needed.

* **Custom paths:** Override key paths with the `SIGN_CERT` and `SIGN_KEY` environment variables.
* **Cleanup:** Remove `/etc/pki/fwupd/LOCAL-CA.pem` to revoke local trust. Anyone holding `key.pem` can sign firmware your `fwupd` will accept, so keep it private.

### Option 2: Disable Signature Verification

Bypass signature checks in `fwupd`:

```bash
sudo sed -i '/^\[fwupd\]/,/^\[/ s/^#*\s*OnlyTrusted\s*=.*/OnlyTrusted=false/' /etc/fwupd/fwupd.conf
grep -q '^OnlyTrusted=false' /etc/fwupd/fwupd.conf || sudo sed -i '/^\[fwupd\]/a OnlyTrusted=false' /etc/fwupd/fwupd.conf
sudo systemctl restart fwupd
```

Confirm the key landed in the right section:

```bash
sed -n '/^\[fwupd\]/,/^\[/p' /etc/fwupd/fwupd.conf | grep OnlyTrusted
```

`fwupd.conf` holds several sections (`[fwupd]`, `[uefi_capsule]`, `[redfish]`, and others), and `OnlyTrusted` is only read from `[fwupd]`. Appending with `tee -a` puts the key under whichever section happens to be last in the file, where `fwupd` ignores it while `[fwupd]` keeps `OnlyTrusted=true`, so the setting appears applied but changes nothing. The first command rewrites the key in place if present, and the second inserts it under `[fwupd]` if the file does not ship one.

Disables payload verification across all devices and `.cab` archives managed by `fwupd`.

### Secure Boot

Secure Boot validates EFI binaries at boot rather than `.cab` packages or the `OnlyTrusted` setting:

1. `fwupd` copies `fwupdx64.efi` to the ESP and updates `BootNext` to stage the update.
2. `shim` verifies `fwupdx64.efi` during boot. Install distribution-provided binaries (`fwupd-efi` on Fedora, Debian, Ubuntu) rather than compiling from source.

**Troubleshooting:** If the capsule update fails to run on reboot, disable Secure Boot in UEFI, apply the update, allow the firmware to flash, and re-enable Secure Boot.

## Tested laptops

| Model                 | Status          |
|-----------------------|-----------------|
| Legion Pro 7 16IAX10H | Tested, working |
| IdeaPad Pro 5 16IAH10 | Tested, working |
| Yoga 9 2in-1 14ILL10  | Tested, working |
| Legion 5 15AHP10      | Tested, working |
| Legion Slim 5 16ARP9  | Tested, working |

This script should work on other Lenovo laptops that use Insyde H2OFFT-based BIOS updates with a `.fd` or `.rom` firmware file inside the `.exe`. If you test it on another model, please open an issue or PR to update this table.

## License

GPLv2. See [LICENSE](LICENSE).
