#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

work=''
boot_mount=''
iso_mount=''
owns_boot_mount=0
rollback_needed=0
committed=0
old_iso_path=''
new_iso_path=''
rollback_config=''
staged_iso=''
final_config=''

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'Usage: sudo bash update-lightwhale.sh <ISO_HTTPS_URL>\n'
}

cleanup() {
    local status=$?
    local mounted=0
    local rollback_ok=1
    local path

    trap - EXIT

    if (( status != 0 && ! committed )); then
        if (( rollback_needed )); then
            printf 'Upgrade failed; restoring the previous GRUB config.\n' >&2
            if [[ -n $rollback_config && -f $rollback_config ]]; then
                mv -f -- "$rollback_config" "$boot_mount/boot/grub/grub.cfg" ||
                    rollback_ok=0
            else
                rollback_ok=0
            fi
            sync || rollback_ok=0
        fi
        if (( rollback_ok )) && [[ -n $new_iso_path && -e $new_iso_path ]]; then
            rm -f -- "$new_iso_path" ||
                printf 'Could not remove inactive ISO: %s\n' "$new_iso_path" >&2
        elif (( ! rollback_ok )); then
            printf 'Could not restore the old boot config; leaving the new ISO in place at %s.\n' \
                "$new_iso_path" >&2
        fi
    fi

    if [[ -n $iso_mount ]] && mountpoint -q "$iso_mount"; then
        umount "$iso_mount" || { status=1; mounted=1; }
    fi
    if (( owns_boot_mount )) && [[ -n $boot_mount ]] && mountpoint -q "$boot_mount"; then
        umount "$boot_mount" || { status=1; mounted=1; }
    fi

    for path in "$staged_iso" "$rollback_config" "$final_config"; do
        if [[ -n $path && -e $path ]]; then
            rm -f -- "$path" || status=1
        fi
    done

    if [[ -n $work && $mounted == 0 ]]; then
        rm -rf -- "$work"
    elif [[ -n $work ]]; then
        printf 'Could not unmount temporary filesystems; leaving %s intact.\n' "$work" >&2
    fi

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( $# == 1 )) && [[ $1 == --help || $1 == -h ]]; then
    usage
    exit 0
fi
if (( $# != 1 )); then
    usage >&2
    exit 2
fi
url=$1
[[ $url == https://* ]] || die 'Use an HTTPS ISO URL.'
(( EUID == 0 )) || die 'Run with sudo.'

for command_name in awk blkid chmod cmp cp curl date df findmnt grep mount mountpoint mv mktemp readlink rm sed stat sync umount; do
    command -v "$command_name" >/dev/null || die "Missing command: $command_name"
done

mapfile -t boot_parts < <(blkid -t LABEL=LWBOOT -o device)
(( ${#boot_parts[@]} == 1 )) ||
    die "Expected exactly one filesystem labeled LWBOOT; found ${#boot_parts[@]}."
boot_part=$(readlink -f -- "${boot_parts[0]}")
[[ -b $boot_part ]] || die "LWBOOT is not a block device: $boot_part"
boot_type=$(blkid -s TYPE -o value "$boot_part")
[[ $boot_type == ext2 || $boot_type == ext3 || $boot_type == ext4 ]] ||
    die "Unsupported LWBOOT filesystem: $boot_type"

work=$(mktemp -d /var/tmp/lightwhale-update.XXXXXXXX)
iso_mount=$work/newiso
mkdir "$iso_mount"

mapfile -t mounted_targets < <(findmnt -rn -S "$boot_part" -o TARGET)
if (( ${#mounted_targets[@]} > 1 )); then
    die 'LWBOOT is mounted more than once; unmount it and retry.'
elif (( ${#mounted_targets[@]} == 1 )); then
    boot_mount=${mounted_targets[0]}
else
    boot_mount=$work/startup
    mkdir "$boot_mount"
    mount "$boot_part" "$boot_mount"
    owns_boot_mount=1
fi

[[ -d $boot_mount/iso ]] || die 'LWBOOT does not contain the iso directory.'
[[ -s $boot_mount/boot/grub/grub.cfg ]] ||
    die 'LWBOOT does not contain boot/grub/grub.cfg.'

say() {
    printf '\n%s\n' "$*"
}

say 'Downloading and validating the new Lightwhale ISO'
curl --fail --location \
    --proto '=https' \
    --proto-redir '=https' \
    --retry 3 \
    --connect-timeout 30 \
    --progress-bar \
    --output "$work/lightwhale.iso" \
    "$url"

mount -t iso9660 -o loop,ro,nosuid,nodev,noexec \
    "$work/lightwhale.iso" "$iso_mount"
for required_file in boot/lightwhale-kernel boot/lightwhale-rootfs boot/grub/grub.cfg; do
    [[ -s $iso_mount/$required_file ]] || die "Unsupported ISO: missing $required_file"
done

new_ramdisk_kb=$(awk '
    {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^ramdisk_size=[0-9]+$/) {
                sub(/^ramdisk_size=/, "", $i)
                print $i
                exit
            }
        }
    }
' "$iso_mount/boot/grub/grub.cfg")
[[ $new_ramdisk_kb =~ ^[0-9]+$ ]] ||
    die 'New ISO has no numeric ramdisk_size in its GRUB configuration.'
new_ramdisk_kb=$((10#$new_ramdisk_kb))
(( new_ramdisk_kb > 0 && new_ramdisk_kb <= 2147483647 )) ||
    die 'New ISO ramdisk_size is outside the supported range.'
rootfs_bytes=$(stat -c %s "$iso_mount/boot/lightwhale-rootfs")
(( new_ramdisk_kb >= (rootfs_bytes + 1023) / 1024 )) ||
    die 'New ISO ramdisk_size is smaller than its root filesystem.'
umount "$iso_mount"

current_config=$boot_mount/boot/grub/grub.cfg
loopback_count=$(grep -Ec '^[[:space:]]*loopback[[:space:]]+loop[[:space:]]+/iso/[A-Za-z0-9._-]+\.iso[[:space:]]*$' "$current_config" || true)
(( loopback_count == 1 )) ||
    die 'Expected exactly one loopback ISO path under /iso in the installed GRUB config.'
old_iso_rel=$(awk '
    $1 == "loopback" && $2 == "loop" && $3 ~ /^\/iso\/[A-Za-z0-9._-]+\.iso$/ {
        print $3
    }
' "$current_config")
old_iso_path=$boot_mount$old_iso_rel
[[ -s $old_iso_path ]] || die "Installed GRUB ISO is missing: $old_iso_path"

ramdisk_count=$(grep -Ec '(^|[[:space:]])ramdisk_size=[0-9]+([[:space:]]|$)' "$current_config" || true)
(( ramdisk_count == 1 )) ||
    die 'Expected exactly one numeric ramdisk_size in the installed GRUB config.'
old_ramdisk_kb=$(awk '
    {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^ramdisk_size=[0-9]+$/) {
                sub(/^ramdisk_size=/, "", $i)
                print $i
                exit
            }
        }
    }
' "$current_config")
old_ramdisk_kb=$((10#$old_ramdisk_kb))
(( old_ramdisk_kb > 0 && old_ramdisk_kb <= 2147483647 )) ||
    die 'Installed GRUB ramdisk_size is outside the supported range.'

new_iso_bytes=$(stat -c %s "$work/lightwhale.iso")

# Remove only orphaned images created by this updater, never the active GRUB target.
for orphan in "$boot_mount"/iso/lightwhale-update-*.iso; do
    [[ -e $orphan ]] || continue
    [[ $orphan == "$old_iso_path" ]] && continue
    rm -f -- "$orphan" || die "Could not remove orphaned update ISO: $orphan"
done

available_bytes=$(df -B1 --output=avail "$boot_mount" | awk 'NR == 2 { print $1 }')
[[ $available_bytes =~ ^[0-9]+$ ]] || die 'Could not determine free space on LWBOOT.'
(( available_bytes >= new_iso_bytes + 1048576 )) ||
    die 'Not enough free space on LWBOOT to stage the new ISO safely.'

stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
new_iso_basename=lightwhale-update-$stamp.iso
new_iso_rel=/iso/$new_iso_basename
new_iso_path=$boot_mount$new_iso_rel
[[ ! -e $new_iso_path ]] || die 'New ISO filename collision; retry the update.'

staged_iso=$(mktemp "$boot_mount/iso/.lightwhale.iso.new.XXXXXX")
cp -- "$work/lightwhale.iso" "$staged_iso"
cmp -- "$work/lightwhale.iso" "$staged_iso" || die 'Staged ISO verification failed.'
chmod --reference="$old_iso_path" "$staged_iso"
mv -- "$staged_iso" "$new_iso_path"
staged_iso=''

final_config=$(mktemp "$boot_mount/boot/grub/.grub.cfg.update.XXXXXX")
rollback_config=$(mktemp "$boot_mount/boot/grub/.grub.cfg.rollback.XXXXXX")
cp -p -- "$current_config" "$rollback_config"
sed -E \
    -e "s|(^[[:space:]]*loopback[[:space:]]+loop[[:space:]]+)/iso/[A-Za-z0-9._-]+\\.iso([[:space:]]*)$|\\1$new_iso_rel\\2|" \
    -e "s/ramdisk_size=[0-9]+/ramdisk_size=$new_ramdisk_kb/" \
    "$current_config" > "$final_config"
chmod --reference="$current_config" "$final_config"
new_loopback_count=$(grep -Fc "loopback loop $new_iso_rel" "$final_config" || true)
(( new_loopback_count == 1 )) || die 'Could not prepare the new GRUB ISO path.'
new_ramdisk_count=$(grep -Fc "ramdisk_size=$new_ramdisk_kb" "$final_config" || true)
(( new_ramdisk_count == 1 )) || die 'Could not prepare the new GRUB ramdisk_size.'

say 'Switching GRUB atomically to the validated ISO'
rollback_needed=1
sync
mv -f -- "$final_config" "$current_config"
final_config=''
sync
committed=1
rollback_needed=0
trap '' INT TERM

rm -f -- "$old_iso_path" ||
    printf 'Warning: old inactive ISO could not be removed: %s\n' "$old_iso_path" >&2

rm -f -- "$rollback_config" ||
    printf 'Warning: temporary rollback config could not be removed: %s\n' "$rollback_config" >&2
rollback_config=''
sync || printf 'Warning: final filesystem sync reported an error.\n' >&2

printf '\nUpgrade staged successfully. GRUB ramdisk_size is %s KiB.\n' "$new_ramdisk_kb"
printf 'Active ISO: %s\n' "$new_iso_rel"
printf 'Reboot to start Lightwhale from the new ISO.\n'