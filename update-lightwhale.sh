#!/usr/bin/env bash
# Upgrade the Lightwhale ISO on the LWBOOT partition created by install.sh.
# Works from a rescue OS or in place on the running Lightwhale system.
#
# Default: the new ISO is downloaded straight onto LWBOOT (no RAM/tmp usage), validated, and
# only then GRUB is switched; the old ISO stays active until that moment and is removed after.
# --low-space: for a LWBOOT too small to hold two ISOs; stages in /var/tmp and replaces in place.
set -Eeuo pipefail
export LC_ALL=C

work='' boot_mount='' iso_mount='' stage='' rollback_config='' final_config=''
old_iso_path='' old_iso_backup='' new_iso_path='' iso_mode='' new_boot_layout='' new_ramdisk_kb=''
owns_boot_mount=0 rollback_needed=0 committed=0 force_replace=0 low_space=0

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
say() { printf '\n%s\n' "$*"; }
usage() { printf 'Usage: sudo bash update-lightwhale.sh [--force] [--low-space] <ISO_HTTPS_URL>\n'; }

# Print a file's octal mode, failing if it cannot be determined.
mode_of() {
    local m
    m=$(stat -c %a "$1")
    [[ $m =~ ^[0-7]{3,4}$ ]] || die "Could not determine file mode: $1"
    printf '%s' "$m"
}

# Print free KiB on the filesystem holding $1.
free_kb() {
    local kb
    kb=$(df -Pk "$1" | awk 'NR == 2 { print $4 }')
    [[ $kb =~ ^[0-9]+$ ]] || die "Could not determine free space for $1."
    printf '%s' "$kb"
}

# Copy $1 to $2, set mode $3, and verify the result byte for byte (returns status, never exits).
copy_verified() {
    cp -- "$1" "$2" && chmod "$3" "$2" && cmp -- "$1" "$2"
}

# GRUB adds this init and the ISO's squashfs to the upstream initramfs.
# Keep in sync with install.sh.
write_initramfs_init() {
    cat > "$1" <<'EOF'
#!/bin/sh
fail() { echo "$*" >&2; exec /bin/sh; }
mount -t devtmpfs devtmpfs /dev || fail 'Cannot mount /dev'
mount -t proc proc /proc || fail 'Cannot mount /proc'
mount -t sysfs sysfs /sys || fail 'Cannot mount /sys'
if (exec 0</dev/console) 2>/dev/null; then
    exec 0</dev/console 1>/dev/console 2>/dev/console
fi
mkdir /rootfs || fail 'Cannot create /rootfs'
mount -t squashfs -o loop,ro /rootfs.squashfs /rootfs || fail 'Cannot mount Lightwhale root filesystem'
mount -o move /dev /rootfs/dev || fail 'Cannot move /dev'
mount -o move /proc /rootfs/proc || fail 'Cannot move /proc'
mount -o move /sys /rootfs/sys || fail 'Cannot move /sys'
exec switch_root /rootfs /sbin/init "$@"
EOF
}

# Validate the ISO at $1 and detect its boot layout (sets new_boot_layout, new_ramdisk_kb).
validate_iso() {
    local f rootfs_bytes
    mount -t iso9660 -o loop,ro,nosuid,nodev,noexec "$1" "$iso_mount"
    for f in boot/lightwhale-kernel boot/lightwhale-rootfs boot/grub/grub.cfg; do
        [[ -s $iso_mount/$f ]] || die "Unsupported ISO: missing $f"
    done

    new_ramdisk_kb=$(awk '
        $1 == "linux" {
            for (i = 2; i <= NF; i++)
                if (sub(/^ramdisk_size=/, "", $i) && $i ~ /^[0-9]+$/) { print $i; exit }
        }' "$iso_mount/boot/grub/grub.cfg")

    if [[ $new_ramdisk_kb =~ ^[0-9]+$ ]]; then
        new_boot_layout=ramdisk
        new_ramdisk_kb=$((10#$new_ramdisk_kb))
        (( new_ramdisk_kb > 0 && new_ramdisk_kb <= 2147483647 )) ||
            die 'New ISO ramdisk_size is outside the supported range.'
        rootfs_bytes=$(stat -c %s "$iso_mount/boot/lightwhale-rootfs")
        (( new_ramdisk_kb >= (rootfs_bytes + 1023) / 1024 )) ||
            die 'New ISO ramdisk_size is smaller than its root filesystem.'
    elif [[ -s $iso_mount/boot/lightwhale-initramfs ]]; then
        new_boot_layout=initramfs
    else
        die 'New ISO has no numeric ramdisk_size and no lightwhale-initramfs in its GRUB configuration.'
    fi
    umount "$iso_mount"
}

# Restore the previous GRUB config and ISO after a failure before the switch.
rollback() {
    local ok=1
    printf 'Upgrade failed; restoring the previous GRUB config.\n' >&2

    if [[ -f $rollback_config ]]; then
        mv -f -- "$rollback_config" "$boot_mount/boot/grub/grub.cfg" || ok=0
    else
        ok=0
    fi
    sync || ok=0

    if (( ok )); then
        if [[ $new_iso_path != "$old_iso_path" && -e $new_iso_path ]]; then
            rm -f -- "$new_iso_path" || ok=0
        fi
        if [[ -s $old_iso_backup ]]; then
            rm -f -- "$old_iso_path" || ok=0
            copy_verified "$old_iso_backup" "$old_iso_path" "$iso_mode" || ok=0
        elif [[ ! -s $old_iso_path ]]; then
            ok=0
        fi
    fi

    (( ok )) || printf 'Rollback was incomplete; inspect %s and %s manually.\n' "$boot_mount" "$work" >&2
}

cleanup() {
    local status=$? stuck=0 path
    trap - EXIT

    if (( status != 0 && ! committed && rollback_needed )); then
        rollback
    fi

    if [[ -n $iso_mount ]] && mountpoint -q "$iso_mount"; then
        umount "$iso_mount" || { status=1; stuck=1; }
    fi
    for path in "$rollback_config" "$final_config" "$stage"; do
        if [[ -n $path && -e $path ]]; then rm -f -- "$path" || status=1; fi
    done
    if (( owns_boot_mount )) && mountpoint -q "$boot_mount"; then
        umount "$boot_mount" || { status=1; stuck=1; }
    fi

    if [[ -z $work ]]; then
        :
    elif (( stuck )); then
        printf 'Could not unmount temporary filesystems; leaving %s intact.\n' "$work" >&2
    else
        rm -rf -- "$work"
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while (( $# )); do
    case $1 in
        --help|-h) usage; exit 0 ;;
        --force) force_replace=1; shift ;;
        --low-space) low_space=1; shift ;;
        --atomic) shift ;;  # now the default; accepted for compatibility
        --) shift; break ;;
        *) break ;;
    esac
done
(( $# == 1 )) || { usage >&2; exit 2; }

url=$1
[[ $url == https://* ]] || die 'Use an HTTPS ISO URL.'
url_path=${url%%#*}
url_path=${url_path%%\?*}
new_iso_base=${url_path##*/}
[[ $new_iso_base =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.iso$ ]] ||
    die 'ISO URL must end with a safe .iso filename.'
(( EUID == 0 )) || die 'Run with sudo.'

for cmd in awk blkid chmod cmp cp curl date df findmnt grep mount mountpoint mv mktemp readlink rm stat sync tr umount; do
    command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done

# --- Locate and mount LWBOOT ------------------------------------------------
mapfile -t boot_parts < <(blkid -t LABEL=LWBOOT -o device)
(( ${#boot_parts[@]} == 1 )) ||
    die "Expected exactly one filesystem labeled LWBOOT; found ${#boot_parts[@]}."
boot_part=$(readlink -f -- "${boot_parts[0]}")
[[ -b $boot_part ]] || die "LWBOOT is not a block device: $boot_part"
boot_type=$(blkid -s TYPE -o value "$boot_part")
[[ $boot_type == ext[234] ]] || die "Unsupported LWBOOT filesystem: $boot_type"

work=$(mktemp -d /var/tmp/lightwhale-update.XXXXXXXX)
iso_mount=$work/newiso
mkdir "$iso_mount"

mapfile -t mounted_targets < <(findmnt -rn -S "$boot_part" -o TARGET)
if (( ${#mounted_targets[@]} > 1 )); then
    die 'LWBOOT is mounted more than once; unmount it and retry.'
elif (( ${#mounted_targets[@]} == 1 )); then
    boot_mount=${mounted_targets[0]}
    if findmnt -rn -o OPTIONS "$boot_mount" | tr , '\n' | grep -qx ro; then
        die 'LWBOOT is mounted read-only; remount it read-write or unmount it and retry.'
    fi
else
    boot_mount=$work/startup
    mkdir "$boot_mount"
    mount "$boot_part" "$boot_mount"
    owns_boot_mount=1
fi

current_config=$boot_mount/boot/grub/grub.cfg
[[ -d $boot_mount/iso ]] || die 'LWBOOT does not contain the iso directory.'
[[ -s $current_config ]] || die 'LWBOOT does not contain boot/grub/grub.cfg.'

# --- Inspect the installed GRUB config (before downloading anything) --------
loopback_count=$(grep -Ec '^[[:space:]]*loopback[[:space:]]+loop[[:space:]]+/iso/[A-Za-z0-9._-]+\.iso[[:space:]]*$' "$current_config" || true)
(( loopback_count == 1 )) ||
    die 'Expected exactly one loopback ISO path under /iso in the installed GRUB config.'
old_iso_rel=$(awk '$1 == "loopback" && $2 == "loop" && $3 ~ /^\/iso\/[A-Za-z0-9._-]+\.iso$/ { print $3 }' "$current_config")
old_iso_path=$boot_mount$old_iso_rel
[[ -s $old_iso_path ]] || die "Installed GRUB ISO is missing: $old_iso_path"

kernel_count=$(grep -Ec '^[[:space:]]*linux[[:space:]]+\(loop\)/boot/lightwhale-kernel([[:space:]]|$)' "$current_config" || true)
initrd_count=$(grep -Ec '^[[:space:]]*initrd[[:space:]]+\(loop\)/boot/lightwhale-(rootfs|initramfs)([[:space:]]|$)' "$current_config" || true)
(( kernel_count == 1 && initrd_count == 1 )) ||
    die 'Expected exactly one Lightwhale kernel and initrd in the installed GRUB config.'

iso_mode=$(mode_of "$old_iso_path")
old_iso_bytes=$(stat -c %s "$old_iso_path")
old_iso_base=${old_iso_rel##*/}

# New ISO name. Staged mode never overwrites the active file, so a repeated name (e.g. the
# "latest" URL) gets a timestamp; low-space mode replaces the file in place.
new_iso_rel=/iso/$new_iso_base
if (( ! low_space )) && [[ $new_iso_base == "$old_iso_base" ]]; then
    new_iso_rel=/iso/${new_iso_base%.iso}-$(date +%Y%m%d%H%M%S).iso
fi
new_iso_path=$boot_mount$new_iso_rel

if [[ $new_iso_path != "$old_iso_path" && ( -e $new_iso_path || -L $new_iso_path ) ]]; then
    [[ -f $new_iso_path && ! -L $new_iso_path ]] ||
        die "Refusing to replace a non-regular ISO path: $new_iso_path"
    (( force_replace )) ||
        die "The destination ISO already exists but is not active; use --force to replace it: $new_iso_path"
fi

# Remove leftovers from interrupted runs, never the active GRUB target.
for orphan in "$boot_mount"/iso/.lightwhale-update.* "$boot_mount"/iso/lightwhale-update-*.iso; do
    [[ -e $orphan && $orphan != "$old_iso_path" && $orphan != "$new_iso_path" ]] || continue
    rm -f -- "$orphan" || die "Could not remove orphaned update file: $orphan"
done

# --- Download the new ISO ---------------------------------------------------
if (( low_space )); then
    [[ $(stat -c %d "$work") != "$(stat -c %d "$boot_mount")" ]] ||
        die 'Temporary workspace must be on a different filesystem than LWBOOT.'
    iso_src=$work/lightwhale.iso
else
    # Best-effort early space check from Content-Length; the download itself still fails safely.
    remote_bytes=$(curl -sIL --proto '=https' --proto-redir '=https' --connect-timeout 30 "$url" 2>/dev/null |
        awk 'tolower($1) == "content-length:" { v = $2 } END { gsub(/\r/, "", v); print v }' || true)
    if [[ $remote_bytes =~ ^[0-9]+$ ]] &&
        (( $(free_kb "$boot_mount") < (remote_bytes + 1048576 + 1023) / 1024 )); then
        die 'Not enough free space on LWBOOT to stage the new ISO beside the active one; free space or use --low-space.'
    fi
    iso_src=$(mktemp "$boot_mount/iso/.lightwhale-update.XXXXXX")
    stage=$iso_src
fi

say 'Downloading and validating the new Lightwhale ISO'
curl --fail --location --proto '=https' --proto-redir '=https' \
    --retry 3 --connect-timeout 30 --progress-bar \
    --output "$iso_src" "$url" ||
    die 'Download failed (check the network and free space; consider --low-space).'

validate_iso "$iso_src"
new_iso_bytes=$(stat -c %s "$iso_src")

if [[ $new_iso_base == "$old_iso_base" ]] && (( ! force_replace )) && cmp -s -- "$iso_src" "$old_iso_path"; then
    say "ISO $new_iso_base is already active; nothing to update."
    exit 0
fi

if (( low_space )); then
    (( $(free_kb "$work") >= 1024 + (old_iso_bytes + 1023) / 1024 )) ||
        die 'Not enough temporary space to preserve the current ISO for rollback.'
fi

# --- Prepare the new GRUB config --------------------------------------------
final_config=$(mktemp "$boot_mount/boot/grub/.grub.cfg.update.XXXXXX")
rollback_config=$(mktemp "$boot_mount/boot/grub/.grub.cfg.rollback.XXXXXX")
cp -p -- "$current_config" "$rollback_config"

if [[ $new_boot_layout == initramfs ]]; then
    initrd_args='(loop)/boot/lightwhale-initramfs newc:rootfs.squashfs:(loop)/boot/lightwhale-rootfs newc:init:/boot/grub/lightwhale-init'
    write_initramfs_init "$work/lightwhale-init"
    cp -- "$work/lightwhale-init" "$boot_mount/boot/grub/lightwhale-init"
    chmod 644 "$boot_mount/boot/grub/lightwhale-init"
else
    initrd_args='(loop)/boot/lightwhale-rootfs'
fi
awk -v iso="$new_iso_rel" -v layout="$new_boot_layout" -v size="$new_ramdisk_kb" -v initrd="$initrd_args" '
    $1 == "loopback" && $2 == "loop" && $3 ~ /^\/iso\/[A-Za-z0-9._-]+\.iso$/ {
        sub(/\/iso\/[A-Za-z0-9._-]+\.iso/, iso)
    }
    $1 == "linux" && $2 == "(loop)/boot/lightwhale-kernel" {
        $0 = "    linux (loop)/boot/lightwhale-kernel " (layout == "ramdisk" ? "root=/dev/ram0 ramdisk_size=" size " " : "") "console=tty0 consoleblank=300"
    }
    $1 == "initrd" && ($2 == "(loop)/boot/lightwhale-rootfs" || $2 == "(loop)/boot/lightwhale-initramfs") {
        $0 = "    initrd " initrd
    }
    { print }
' "$current_config" > "$final_config"
chmod "$(mode_of "$current_config")" "$final_config"
[[ $(grep -Fc "loopback loop $new_iso_rel" "$final_config" || true) == 1 ]] ||
    die 'Could not prepare the new GRUB ISO path.'
grep -Fq "initrd $initrd_args" "$final_config" || die 'Could not prepare the new GRUB initrd.'

# --- Put the new ISO in place -----------------------------------------------
if (( low_space )); then
    old_iso_backup=$work/previous-lightwhale.iso
    cp -- "$old_iso_path" "$old_iso_backup"
    cmp -- "$old_iso_path" "$old_iso_backup" || die 'Could not verify the temporary backup of the current ISO.'
    sync
    rollback_needed=1

    say 'Replacing the ISO using the validated temporary download'
    rm -f -- "$old_iso_path" "$new_iso_path"
    (( $(free_kb "$boot_mount") >= (new_iso_bytes + 1048576 + 1023) / 1024 )) ||
        die 'Not enough free space on LWBOOT after removing the old ISO; restoring it.'
    copy_verified "$iso_src" "$new_iso_path" "$iso_mode" || die 'Copied ISO verification failed.'
else
    say 'Activating the downloaded ISO beside the active one'
    chmod "$iso_mode" "$stage"
    sync
    rollback_needed=1
    mv -f -- "$stage" "$new_iso_path"  # atomic rename within LWBOOT
    stage=''
fi
sync

# --- Commit -----------------------------------------------------------------
say 'Switching GRUB atomically to the validated ISO'
mv -f -- "$final_config" "$current_config"
final_config=''
sync
committed=1
rollback_needed=0
trap '' INT TERM

if [[ $old_iso_path != "$new_iso_path" ]]; then
    rm -f -- "$old_iso_path" ||
        printf 'Warning: old inactive ISO could not be removed: %s\n' "$old_iso_path" >&2
fi
rm -f -- "$rollback_config" ||
    printf 'Warning: temporary rollback config could not be removed: %s\n' "$rollback_config" >&2
rollback_config=''
sync || printf 'Warning: final filesystem sync reported an error.\n' >&2

printf '\nUpgrade staged successfully. Boot layout: %s.\n' "$new_boot_layout"
printf 'Active ISO: %s\n' "$new_iso_rel"
printf 'Reboot to start Lightwhale from the new ISO.\n'
