# vmware-secureboot-setup

Fix VMware Workstation on Fedora (and other RPM-based distros) with Secure Boot enabled. Run it once, forget about it forever.

## The Problem

VMware Workstation requires two kernel modules (`vmmon` and `vmnet`). Secure Boot blocks unsigned kernel modules. Every kernel update recompiles the modules, stripping their signatures. Every VMware update replaces them entirely. You end up Googling the same fix every time:

```
Could not open /dev/vmmon: No such file or directory.
Please make sure that the kernel module 'vmmon' is loaded.
```

## What This Script Does

1. **Generates a MOK key pair** (or reuses an existing one) and enrolls it with your UEFI firmware
2. **Compiles VMware kernel modules** if missing for the running kernel
3. **Signs both modules** (`vmmon.ko`, `vmnet.ko`) with your MOK private key
4. **Installs a systemd service** that auto-compiles and signs modules on every boot
5. **Patches VMware's init script** to auto-sign modules on any mid-session recompile

After one run (and a reboot to enroll the MOK key), VMware survives every kernel update and every VMware update without manual intervention.

## Requirements

- VMware Workstation (already installed)
- Fedora (or any RPM-based distro with Secure Boot enabled)
- `kernel-devel` for your running kernel
- `mokutil` and `openssl` (pre-installed on most Fedora systems)

```bash
sudo dnf install kernel-devel-$(uname -r) mokutil openssl
```

## Usage

```bash
# Download
curl -O https://raw.githubusercontent.com/<your-username>/vmware-secureboot-setup/main/vmware-secureboot-setup.sh
chmod +x vmware-secureboot-setup.sh

# Run
sudo ./vmware-secureboot-setup.sh
```

### First Run

If this is your first time (no MOK key enrolled yet), the script will prompt you to set a one-time password and then ask you to reboot.

On reboot, the **MOK Manager** appears before your OS boots:

1. Select **Enroll MOK**
2. Select **Continue**
3. Enter the password you set
4. Reboot

After rebooting, run the script again to sign the modules:

```bash
sudo ./vmware-secureboot-setup.sh
```

That's it. You won't need to touch this again.

## How It Works

### Why MOK, Not "Just Disable Secure Boot"

Secure Boot prevents bootkits and unsigned kernel code from running at ring 0. Disabling it removes a real security boundary. MOK (Machine Owner Key) extends the trust chain to include a key you control — your modules load normally, and Secure Boot stays on.

### Two Auto-Sign Mechanisms (Belt and Suspenders)

| Mechanism | Catches | How |
|-----------|---------|-----|
| **systemd service** (`vmware-sign-modules.service`) | Kernel updates | Runs before `vmware.service` on every boot — compiles and signs modules if needed |
| **Init script patch** | VMware updates | Injects `vmwareSignModule()` before each `modprobe` call in VMware's own init script |

### Permission Fixes

VMware's launcher runs `modprobe -n` (dry-run) as a non-root user to check if modules exist. On some Fedora configurations, restrictive permissions on `/lib/modules/<kver>/misc/` cause this check to fail even when modules are present. The script fixes this with appropriate read permissions.

## Verification

```bash
# Confirm Secure Boot is enabled
mokutil --sb-state

# Confirm your MOK key is enrolled
mokutil --list-enrolled | grep "VMware Module Signing"

# Confirm modules are loaded
lsmod | grep -E "vmmon|vmnet"

# Confirm modules are signed
modinfo /lib/modules/$(uname -r)/misc/vmmon.ko | grep signer
```

## Troubleshooting

### "sign-file not found for kernel X.X.X"

Install `kernel-devel` for your running kernel:

```bash
sudo dnf install kernel-devel-$(uname -r)
```

### "vmware-modconfig not found"

VMware Workstation isn't installed, or its binaries aren't in `$PATH`.

### Modules still won't load after signing

Verify your MOK key is enrolled:

```bash
mokutil --test-key /etc/pki/vmware/MOK.der
```

If it says "not enrolled," reboot and complete the MOK Manager enrollment step.

### VMware update overwrote the init script patch

Re-run the script. It will re-apply the patch:

```bash
sudo ./vmware-secureboot-setup.sh
```

## File Locations

| File | Purpose |
|------|---------|
| `/etc/pki/vmware/MOK.priv` | MOK private key (mode 600) |
| `/etc/pki/vmware/MOK.der` | MOK public certificate (enrolled in UEFI) |
| `/usr/local/bin/vmware-sign-modules` | Auto-sign script called by systemd |
| `/etc/systemd/system/vmware-sign-modules.service` | Systemd unit that runs before VMware |
| `/usr/lib/vmware/scripts/init/vmware` | VMware init script (patched with signing function) |

## Uninstall

```bash
# Remove the systemd service
sudo systemctl disable vmware-sign-modules.service
sudo rm /etc/systemd/system/vmware-sign-modules.service
sudo rm /usr/local/bin/vmware-sign-modules
sudo systemctl daemon-reload

# Remove the MOK key (optional — will prompt for password on next reboot)
sudo mokutil --delete /etc/pki/vmware/MOK.der

# Remove the key pair
sudo rm -rf /etc/pki/vmware

# The init script patch is harmless but can be removed by reinstalling VMware
```

## License

MIT
