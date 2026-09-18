# lenovo-bios-fwupd

_Install BIOS/UEFI firmware updates for modern Lenovo Legion laptops on Linux, without needing Windows!_

lenovo-bios-fwupd converts Lenovo Windows BIOS update `.exe` files (Insyde H2OFFT based) into fwupd-compatible `.cab` files that can be installed from Linux.

Many Lenovo laptops don't receive BIOS updates through [LVFS](https://fwupd.org/), so the only official update path is a Windows `.exe`. This script extracts the firmware from that `.exe`, reads your system's EFI System Resource Table (ESRT) to get the correct GUID, and packages everything into a `.cab` that `fwupdmgr` can install natively.

## Requirements

- `7z` (p7zip)
- `gcab`
- `fwupdmgr` (fwupd)
- `python3` (optional; used to match the device's version format, falls back to `plain`)

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
6. Package everything into a `.cab` file.

Before installing:

- Add `OnlyTrusted=false` to `/etc/fwupd/fwupd.conf` (the `.cab` is unsigned) and restart fwupd: `sudo systemctl restart fwupd`.
- **Secure Boot:** fwupd needs a distro-signed `fwupdx64.efi` loaded via shim. If the capsule is not applied on reboot, disable Secure Boot in UEFI setup, retry, and re-enable it afterwards.

Then install the resulting `.cab`:

```bash
sudo fwupdmgr install <version>.cab --allow-reinstall --no-reboot-check
```

Reboot to apply the update. The UEFI firmware will apply the capsule during boot.

**Important:** Ensure AC power is connected and battery is above 30% before installing. Do **not** interrupt the reboot after installation.

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
