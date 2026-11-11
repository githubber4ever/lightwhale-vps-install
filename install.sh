#!/usr/bin/env bash
# Provision a dedicated disk for Lightwhale boot and persistence (UEFI or legacy BIOS).
set -Eeuo pipefail
export LC_ALL=C

DEFAULT_URL=https://lightwhale.asklandd.dk/download/lightwhale-latest-x86.iso
DATA_LABEL=lightwhale-please-format-me

bold='' dim='' reset=''
mode='' target='' work='' device='' initial_identity='' grub_install='' grub_modules=''
boot_layout='' ramdisk_kb='' boot_start='' boot_mib='' boot_end='' efi_part='' boot_part='' data_part=''

usage() {
    printf '%s\n' \
        'Usage: sudo bash install.sh' \
        '' \
        'Interactive, destructive installer for a dedicated disk.' \
        'Boot mode (UEFI or legacy BIOS) is detected from the running rescue OS.' \
        'Creates [EFI system | BIOS GRUB] + an ext2 ISO partition + a Lightwhale data partition.' \
        'Run from your VPS provider live/rescue OS, not the target disk or stock Lightwhale.' \
        'Requires Bash 4+, curl, util-linux, parted, e2fsprogs, GRUB modules for the boot mode' \
        '(and dosfstools for UEFI).'
}

say() { printf '\n%s%s%s\n' "$bold" "$*" "$reset"; }
die() { printf '\nError: %s\n' "$*" >&2; exit 1; }
step() { say "$1 / 4  $2"; }

# Unmount temporary filesystems and remove the workspace when safe.
cleanup() {
    local status=$? failed=0 path
    trap - EXIT
    if [[ -n $work ]]; then
        for path in "$work/boot" "$work/efi" "$work/iso"; do
            if mountpoint -q "$path"; then umount "$path" || failed=1; fi
        done
        if (( failed )); then
            printf 'Could not unmount temporary filesystems; leaving %s intact.\n' "$work" >&2
            status=1
        else
            rm -rf -- "$work"
        fi
    fi
    exit "$status"
}

# Require root, an interactive terminal, and every command the chosen mode needs.
check_requirements() {
    local cmd
    local -a commands=(
        curl lsblk blkid blockdev parted partprobe udevadm mkfs.ext2 wipefs
        mount umount mountpoint findmnt readlink awk stat mktemp sync cmp
    )

    (( EUID == 0 )) || die 'Run with sudo bash install.sh.'
    [[ -t 0 && -t 1 ]] || die 'An interactive terminal is required.'

    if [[ -d /sys/firmware/efi ]]; then
        mode=uefi target=x86_64-efi commands+=(mkfs.fat)
    else
        mode=bios target=i386-pc
    fi

    for cmd in "${commands[@]}"; do
        command -v "$cmd" >/dev/null || die "Missing command: $cmd"
    done
}

# Locate a GRUB installer and its modules for the detected boot mode.
find_grub() {
    local dir hint
    if command -v grub-install >/dev/null; then
        grub_install=grub-install
    elif command -v grub2-install >/dev/null; then
        grub_install=grub2-install
    else
        die "Install GRUB tools and the $target modules first."
    fi

    for dir in /usr/lib/grub /usr/lib/grub2 /usr/share/grub /usr/share/grub2; do
        if [[ -f $dir/$target/modinfo.sh ]]; then grub_modules=$dir/$target; break; fi
    done

    if [[ -z $grub_modules ]]; then
        if [[ $mode == uefi ]]; then hint='Debian: grub-efi-amd64-bin; Fedora: grub2-efi-x64-modules'
        else hint='Debian: grub-pc-bin; Fedora: grub2-pc-modules'; fi
        die "GRUB $target modules missing ($hint)."
    fi
}

# Explain the destructive operation and select a supported whole disk.
select_disk() {
    local note
    if [[ $mode == uefi ]]; then note='Boot the result in native UEFI mode, not legacy BIOS / CSM mode.'
    else note='Boot the result in legacy BIOS / CSM mode, not UEFI-only mode.'; fi

    say "Lightwhale · ${mode^^} disk setup"
    printf '%s\n\n' \
        'This erases the ENTIRE selected disk, including every existing partition.' \
        "$note" \
        'On first boot Lightwhale will format its data partition automatically.'

    lsblk -dp -o NAME,SIZE,MODEL,TRAN,TYPE

    printf '\nTarget whole disk (for example /dev/sdb; blank cancels): '
    IFS= read -r device
    [[ -n $device ]] || exit 0

    device=$(readlink -f -- "$device")
    [[ -b $device ]] || die 'The target is not a block device.'
    [[ $(lsblk -dnro TYPE "$device") == disk ]] ||
        die 'Select a whole disk, not a partition, loop device, or mapped device.'
    [[ $device =~ ^/dev/(sd[a-z]+|mmcblk[0-9]+|nvme[0-9]+n[0-9]+)$ ]] ||
        die 'Lightwhale provisioning requires an sd*, mmcblk*, or nvme*n* disk (use SATA/SCSI rather than virtio-blk in a VM).'
}

# Reject disks that are read-only, mounted, used as swap, or held by other devices.
check_disk_idle() {
    local node holder

    [[ $(blockdev --getro "$device") == 0 ]] || die 'The disk is read-only.'

    # MOUNTPOINT (singular) exists on every util-linux version and reports [SWAP] too.
    [[ -z $(lsblk -nr -o MOUNTPOINT "$device" | tr -d '[:space:]') ]] ||
        die 'Target has mounted filesystems or active swap. Unmount/disable them first.'

    while IFS= read -r node; do
        for holder in /sys/class/block/"${node##*/}"/holders/*; do
            [[ ! -e $holder ]] || die "Target is in use by ${holder##*/} (RAID/LVM/device mapper)."
        done
        if findmnt -rn -S "$node" >/dev/null; then die "Target is mounted: $node"; fi
    done < <(lsblk -nrpo NAME "$device")
}

# Prompt for an HTTPS ISO URL and download it into a temporary workspace.
download_iso() {
    local url
    printf '\nISO HTTPS URL [%s]: ' "$DEFAULT_URL"
    IFS= read -r url
    url=${url:-$DEFAULT_URL}
    [[ $url == https://* ]] || die 'Use an HTTPS download URL.'

    work=$(mktemp -d /var/tmp/lightwhale-install.XXXXXXXX)
    mkdir "$work/iso" "$work/boot" "$work/efi"

    say 'Downloading and inspecting ISO before touching the disk'
    printf '%sTemporary download: %s%s\n' "$dim" "$work/lightwhale.iso" "$reset"

    curl --fail --location --proto '=https' --proto-redir '=https' \
        --retry 3 --connect-timeout 30 --progress-bar \
        --output "$work/lightwhale.iso" "$url"
}

# Validate the ISO contents and identify its boot layout.
inspect_iso() {
    local file rootfs_bytes

    mount -t iso9660 -o loop,ro,nosuid,nodev,noexec "$work/lightwhale.iso" "$work/iso"

    for file in boot/lightwhale-kernel boot/lightwhale-rootfs boot/grub/grub.cfg; do
        [[ -s $work/iso/$file ]] || die "Not a supported Lightwhale ISO: missing $file"
    done

    ramdisk_kb=$(awk '
        $1 == "linux" {
            for (i = 2; i <= NF; i++)
                if (sub(/^ramdisk_size=/, "", $i) && $i ~ /^[0-9]+$/) { print $i; exit }
        }' "$work/iso/boot/grub/grub.cfg")

    if [[ $ramdisk_kb =~ ^[0-9]+$ ]]; then
        boot_layout=ramdisk
        ramdisk_kb=$((10#$ramdisk_kb))  # avoid octal parsing of leading zeros
        rootfs_bytes=$(stat -c %s "$work/iso/boot/lightwhale-rootfs")
        (( ramdisk_kb >= (rootfs_bytes + 1023) / 1024 )) ||
            die 'ISO ramdisk_size is smaller than its root filesystem.'
    elif [[ -s $work/iso/boot/lightwhale-initramfs ]]; then
        boot_layout=initramfs
    else
        die 'ISO has no numeric ramdisk_size and no lightwhale-initramfs in its GRUB configuration.'
    fi

    umount "$work/iso"
}

# Size the boot partition and ensure sufficient space remains for persistence.
calculate_layout() {
    local iso_bytes disk_bytes

    iso_bytes=$(stat -c %s "$work/lightwhale.iso")
    boot_mib=$(( (iso_bytes + 1048575) / 1048576 + 512 ))
    (( boot_mib >= 2048 )) || boot_mib=2048

    boot_start=3
    if [[ $mode == uefi ]]; then boot_start=513; fi
    boot_end=$((boot_start + boot_mib))

    disk_bytes=$(blockdev --getsize64 "$device")
    (( disk_bytes / 1048576 > boot_end + 1025 )) ||
        die 'Disk too small: need room for the ISO boot partition plus at least 1 GiB of data.'
}

# Require explicit erasure confirmation and recheck the selected disk.
confirm_erasure() {
    local confirmation

    say "Proposed layout: $device"
    if [[ $mode == uefi ]]; then
        printf '  Partition 1   512 MiB     FAT32 EFI system partition\n'
    else
        printf '  Partition 1   2 MiB       BIOS GRUB embedding area\n'
    fi
    printf '  Partition 2   %s MiB    ext2; /iso/lightwhale.iso and GRUB\n' "$boot_mib"
    printf '  Partition 3   remainder   Linux data; name %s\n' "$DATA_LABEL"
    printf '\nALL DATA ON %s WILL BE LOST.\n' "$device"
    printf 'Type exactly "ERASE %s" to continue: ' "$device"

    IFS= read -r confirmation
    if [[ $confirmation != "ERASE $device" ]]; then
        say 'Cancelled. Target disk unchanged.'
        exit 0
    fi

    [[ $(lsblk -dnbo MAJ:MIN,SIZE "$device") == "$initial_identity" ]] ||
        die 'Target device identity changed; restart the installer.'

    check_disk_idle
}

# Print the device node of the partition with the given GPT name.
part_by_label() {
    lsblk -nrpo NAME,PARTLABEL "$device" | awk -v label="$1" '$2 == label { print $1; exit }'
}

# Replace the partition table, then wait for the kernel to expose the new partitions.
create_partitions() {
    local attempt
    local -a first

    if [[ $mode == uefi ]]; then
        first=(mkpart EFI-SYSTEM fat32 1MiB 513MiB set 1 esp on)
    else
        first=(mkpart BIOS-GRUB 1MiB 3MiB set 1 bios_grub on)
    fi

    wipefs --all "$device"  # drop stale GPT/MBR and filesystem signatures
    parted -s -a optimal "$device" -- \
        mklabel gpt "${first[@]}" \
        mkpart LIGHTWHALE-BOOT ext2 "${boot_start}MiB" "${boot_end}MiB" \
        mkpart "$DATA_LABEL" ext4 "${boot_end}MiB" 100%

    partprobe "$device"
    udevadm settle

    for attempt in {1..10}; do
        boot_part=$(part_by_label LIGHTWHALE-BOOT)
        data_part=$(part_by_label "$DATA_LABEL")
        efi_part=''
        if [[ $mode == uefi ]]; then efi_part=$(part_by_label EFI-SYSTEM); fi
        if [[ -b $boot_part && -b $data_part && ( $mode == bios || -b $efi_part ) ]]; then
            return
        fi
        sleep 1
    done
    die 'New partition devices did not appear.'
}

# Clear stale signatures, create filesystems, and mount them.
prepare_filesystems() {
    wipefs --all "$data_part"
    mkfs.ext2 -F -L LWBOOT "$boot_part"
    mount -o nosuid,nodev "$boot_part" "$work/boot"
    mkdir -p "$work/boot/iso" "$work/boot/boot/grub"

    if [[ $mode == uefi ]]; then
        mkfs.fat -F 32 -n EFI-SYSTEM "$efi_part"
        mount -o nosuid,nodev,noexec "$efi_part" "$work/efi"
    fi
}

# GRUB adds this init and the ISO's squashfs to the upstream initramfs.
# Keep in sync with update-lightwhale.sh.
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

# Write a GRUB menu that boots the ISO using its filesystem UUID.
write_grub_config() {
    local boot_uuid linux_args initrd_args

    boot_uuid=$(blkid -s UUID -o value "$boot_part")
    [[ $boot_uuid =~ ^[0-9a-fA-F-]+$ ]] || die 'Could not determine boot filesystem UUID.'

    if [[ $boot_layout == initramfs ]]; then
        write_initramfs_init "$work/boot/boot/grub/lightwhale-init"
        linux_args='console=tty0 consoleblank=300'
        initrd_args='(loop)/boot/lightwhale-initramfs newc:rootfs.squashfs:(loop)/boot/lightwhale-rootfs newc:init:/boot/grub/lightwhale-init'
    else
        linux_args="root=/dev/ram0 ramdisk_size=$ramdisk_kb console=tty0 consoleblank=300"
        initrd_args='(loop)/boot/lightwhale-rootfs'
    fi

    cat > "$work/boot/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
menuentry 'Lightwhale' {
    insmod part_gpt
    insmod ext2
    insmod loopback
    insmod iso9660
    insmod search_fs_uuid
    search --no-floppy --fs-uuid --set=root $boot_uuid
    loopback loop /iso/lightwhale.iso
    linux (loop)/boot/lightwhale-kernel $linux_args
    initrd $initrd_args
}
EOF
}

# Copy and verify the ISO, then install GRUB for the detected boot mode.
install_bootloader() {
    local -a args=(
        --target="$target" --directory="$grub_modules"
        --boot-directory="$work/boot/boot"
        --modules='part_gpt ext2 loopback iso9660 search_fs_uuid linux'
        --recheck
    )

    cp -- "$work/lightwhale.iso" "$work/boot/iso/lightwhale.iso"
    cmp -- "$work/lightwhale.iso" "$work/boot/iso/lightwhale.iso" ||
        die 'Copied ISO verification failed.'
    write_grub_config

    if [[ $mode == uefi ]]; then
        args+=(--efi-directory="$work/efi" --removable)
    else
        args+=("$device")
    fi
    "$grub_install" "${args[@]}"
}

# Verify that the data partition opts into Lightwhale first-boot formatting.
verify_data_partition() {
    [[ $(lsblk -dnro PARTLABEL "$data_part") == "$DATA_LABEL" ]] || die 'Wrong data partition name.'
    [[ $(lsblk -dnro PARTTYPE "$data_part") == 0fc63daf-8483-4772-8e79-3d69d8477de4 ]] ||
        die 'Wrong data partition type.'
    printf 'Ready: %s (Lightwhale will format it; no raw magic header is needed).\n' "$data_part"
}

main() {
    case ${1:-} in
        --help|-h) usage; exit 0 ;;
        '') ;;
        *) usage >&2; exit 2 ;;
    esac
    (( $# <= 1 )) || { usage >&2; exit 2; }

    if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
        bold=$'\e[1m' dim=$'\e[2m' reset=$'\e[0m'
    fi

    trap cleanup EXIT
    trap 'printf "\nInstallation failed at line %s. Do not boot the target until installation succeeds.\n" "$LINENO" >&2' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM

    check_requirements
    find_grub
    select_disk
    check_disk_idle
    initial_identity=$(lsblk -dnbo MAJ:MIN,SIZE "$device")

    download_iso
    inspect_iso
    calculate_layout
    confirm_erasure

    step 1 "Creating GPT and ${mode^^} boot partitions"
    create_partitions
    prepare_filesystems

    step 2 "Writing ISO and installing ${mode^^} GRUB"
    install_bootloader

    step 3 'Checking the data partition opt-in'
    verify_data_partition
    sync
    umount "$work/boot"
    if [[ $mode == uefi ]]; then umount "$work/efi"; fi

    step 4 'Installation complete'
    printf 'Eject the VPS rescue mode / eject the live ISO and restart.\n'
    printf 'Upon first boot, login with `op` / `opsecret` and immediately change password with `passwd`.\n\n'
    printf 'Use update-lightwhale.sh <ISO_HTTPS_URL> to upgrade the ISO and GRUB.\n'
}

main "$@"
