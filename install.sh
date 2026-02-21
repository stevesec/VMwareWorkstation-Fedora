#!/bin/bash
#
# vmware-secureboot-setup — Fix VMware Workstation on Secure Boot systems.
#
# Handles:
#   1. MOK key generation and enrollment
#   2. Module compilation, signing, and permission fixes
#   3. Systemd service for auto-signing on boot
#   4. Patching VMware's init script for auto-signing on recompile
#
# Usage: sudo vmware-secureboot-setup
#

set -euo pipefail

KVER="$(uname -r)"
SIGN="/usr/src/kernels/$KVER/scripts/sign-file"
MOK_DIR="/etc/pki/vmware"
MOK_PRIV="$MOK_DIR/MOK.priv"
MOK_DER="$MOK_DIR/MOK.der"
MODDIR="/lib/modules/$KVER/misc"
INIT_SCRIPT="/usr/lib/vmware/scripts/init/vmware"
SIGN_SERVICE="/etc/systemd/system/vmware-sign-modules.service"
SIGN_SCRIPT="/usr/local/bin/vmware-sign-modules"

# ---------- preflight checks ----------

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must be run as root." >&2
    exit 1
fi

if ! mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
    echo "Secure Boot is not enabled — this script is not needed."
    exit 0
fi

if [ ! -x "$SIGN" ]; then
    echo "Error: sign-file not found for kernel $KVER." >&2
    echo "Install kernel-devel: dnf install kernel-devel-$KVER" >&2
    exit 1
fi

if ! command -v vmware-modconfig &>/dev/null; then
    echo "Error: vmware-modconfig not found — is VMware Workstation installed?" >&2
    exit 1
fi

# ---------- 1. MOK key ----------

if [ -f "$MOK_PRIV" ] && [ -f "$MOK_DER" ]; then
    echo "[1/5] MOK key already exists at $MOK_DIR"
else
    echo "[1/5] Generating MOK key pair..."
    mkdir -p "$MOK_DIR"
    openssl req -new -x509 -newkey rsa:2048 -keyout "$MOK_PRIV" -outform DER \
        -out "$MOK_DER" -nodes -days 36500 -subj "/CN=VMware Module Signing/" \
        -set_serial "0x$(openssl rand -hex 16)"
    chmod 600 "$MOK_PRIV"
    chmod 644 "$MOK_DER"
    echo "  Key pair created."
fi

if mokutil --test-key "$MOK_DER" 2>&1 | grep -q "already enrolled"; then
    echo "  MOK key is already enrolled."
else
    echo "  Enrolling MOK key (you will set a one-time password)..."
    mokutil --import "$MOK_DER"
    echo ""
    echo "  *** REBOOT REQUIRED ***"
    echo "  On next boot the MOK Manager will ask you to enroll the key."
    echo "  Enter the password you just set, then re-run this script."
    echo ""
    NEED_REBOOT=1
fi

# ---------- 2. Compile modules if missing ----------

echo "[2/5] Checking kernel modules..."
if [ ! -f "$MODDIR/vmmon.ko" ] || [ ! -f "$MODDIR/vmnet.ko" ]; then
    echo "  Compiling modules for $KVER..."
    vmware-modconfig --console --install-all 2>&1
fi

# ---------- 3. Sign modules ----------

echo "[3/5] Signing modules..."
if [ "${NEED_REBOOT:-0}" = "1" ]; then
    echo "  Skipping — MOK key not yet enrolled (reboot first)."
else
    for mod in vmmon.ko vmnet.ko; do
        modpath="$MODDIR/$mod"
        if [ ! -f "$modpath" ]; then
            echo "  WARNING: $modpath not found" >&2
            continue
        fi
        if modinfo "$modpath" 2>/dev/null | grep -q "^signer:"; then
            echo "  $mod already signed"
        else
            "$SIGN" sha256 "$MOK_PRIV" "$MOK_DER" "$modpath"
            echo "  $mod signed"
        fi
    done
fi

# Fix permissions so non-root modprobe -n works (VMware's launcher check)
chmod o+rx "$MODDIR" 2>/dev/null || true
chmod o+r /lib/modules/"$KVER"/modules.* 2>/dev/null || true
echo "  Module directory and index permissions fixed."

# ---------- 4. Systemd auto-sign service ----------

echo "[4/5] Installing auto-sign boot service..."

cat > "$SIGN_SCRIPT" << 'SIGNEOF'
#!/bin/bash
set -euo pipefail

KVER="$(uname -r)"
SIGN="/usr/src/kernels/$KVER/scripts/sign-file"
PRIV="/etc/pki/vmware/MOK.priv"
DER="/etc/pki/vmware/MOK.der"
MODDIR="/lib/modules/$KVER/misc"

if [ ! -x "$SIGN" ]; then
    echo "sign-file not found for kernel $KVER — is kernel-devel installed?" >&2
    exit 1
fi

if [ ! -f "$PRIV" ] || [ ! -f "$DER" ]; then
    echo "MOK key pair not found in /etc/pki/vmware/" >&2
    exit 1
fi

# Compile modules if they don't exist for the running kernel
if [ ! -f "$MODDIR/vmmon.ko" ] || [ ! -f "$MODDIR/vmnet.ko" ]; then
    echo "Modules missing for $KVER, compiling..."
    vmware-modconfig --console --install-all 2>&1
fi

# Ensure misc/ dir and module index files are world-readable so
# non-root users can run modprobe -n (VMware's launcher check)
chmod o+rx "$MODDIR" 2>/dev/null
chmod o+r /lib/modules/"$KVER"/modules.* 2>/dev/null

# Sign any unsigned modules
for mod in vmmon.ko vmnet.ko; do
    modpath="$MODDIR/$mod"
    if [ ! -f "$modpath" ]; then
        echo "WARNING: $modpath not found, skipping" >&2
        continue
    fi
    if modinfo "$modpath" 2>/dev/null | grep -q "^signer:"; then
        echo "$mod is already signed, skipping"
    else
        "$SIGN" sha256 "$PRIV" "$DER" "$modpath"
        echo "$mod signed OK"
    fi
done
SIGNEOF
chmod +x "$SIGN_SCRIPT"

cat > "$SIGN_SERVICE" << 'SVCEOF'
[Unit]
Description=Sign VMware kernel modules for Secure Boot
Before=vmware.service
ConditionPathExists=/etc/pki/vmware/MOK.priv
ConditionPathExists=/etc/pki/vmware/MOK.der

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vmware-sign-modules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable vmware-sign-modules.service 2>/dev/null
echo "  vmware-sign-modules.service installed and enabled."

# ---------- 5. Patch VMware init script ----------

echo "[5/5] Patching VMware init script..."

if grep -q "vmwareSignModule" "$INIT_SCRIPT" 2>/dev/null; then
    echo "  Already patched."
else
    # Insert the signing function before vmwareLoadModule and wrap it
    sed -i '/^vmwareLoadModule() {$/,/^}$/ {
        /^vmwareLoadModule() {$/ i\
vmwareSignModule() {\
   local mod="$1"\
   local kver="$(uname -r)"\
   local modpath="/lib/modules/$kver/misc/${mod}.ko"\
   local sign="/usr/src/kernels/$kver/scripts/sign-file"\
   local priv="/etc/pki/vmware/MOK.priv"\
   local der="/etc/pki/vmware/MOK.der"\
\
   [ -f "$modpath" ] || return 0\
   [ -x "$sign" ] \&\& [ -f "$priv" ] \&\& [ -f "$der" ] || return 0\
   if ! /sbin/modinfo "$modpath" 2>/dev/null | grep -q '"'"'^signer:'"'"'; then\
      "$sign" sha256 "$priv" "$der" "$modpath"\
   fi\
   chmod o+rx "/lib/modules/$kver/misc" 2>/dev/null\
   chmod o+r /lib/modules/"$kver"/modules.* 2>/dev/null\
}\

        /\/sbin\/modprobe "\$1"/ s|/sbin/modprobe "\$1"|vmwareSignModule "\$1"\n   /sbin/modprobe "\$1"|
    }' "$INIT_SCRIPT"
    echo "  Init script patched."
fi

# ---------- done ----------

echo ""
if [ "${NEED_REBOOT:-0}" = "1" ]; then
    echo "Setup complete. REBOOT NOW to enroll the MOK key, then re-run this script."
else
    echo "All done. VMware Workstation is ready to use with Secure Boot."
    # Load modules now if not already loaded
    modprobe vmmon 2>/dev/null && modprobe vmnet 2>/dev/null && \
        echo "Modules loaded." || true
fi
