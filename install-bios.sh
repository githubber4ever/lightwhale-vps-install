 #!/usr/bin/env bash
# Provision a dedicated disk for legacy BIOS Lightwhale boot and persistence.
set -Eeuo pipefail
export LC_ALL=C

bold=''
dim=''
reset=''

work=''
device=''
initial_identity=''
url=''
grub_install=''
bios_modules=''
ramdisk_kb=''
boot_mib=''
boot_end=''
boot_part=''
data_part=''

# Print command usage and installation requirements.
usage() {
    printf '%s\n' \
        'Usage: sudo bash install-bios.sh' \
        '' \
        'Interactive, destructive installer for a dedicated disk (legacy BIOS only).' \
        'Creates BIOS GRUB + an ext2 ISO partition + a Lightwhale data partition.' \
        'Run from your VPS provider live/rescue OS, not the target disk or stock Lightwhale.' \
        'Requires Bash 4+, curl, util-linux, parted, e2fsprogs, and GRUB i386-pc modules.'
}

# Handle help requests and reject unexpected arguments.
parse_arguments() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then
        usage
        exit 0
    fi

    if (( $# )); then
        usage >&2
        exit 2
    fi
}

# Enable terminal styling unless color output is disabled.
configure_output() {
    if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
        bold=$'\e[1m'
        dim=$'\e[2m'
        reset=$'\e[0m'
    fi
}

# Print a prominent status message.
say() {
    printf '\n%s%s%s\n' "$bold" "$*" "$reset"
}

# Print an error message and terminate the installer.
die() {
    printf '\nError: %s\n' "$*" >&2
    exit 1
}

# Print a numbered installation step.
step() {
    say "$1 / 4  $2"
}

# Unmount temporary filesystems and remove the workspace when safe.
cleanup() {
    local status=$?
    local failed=0
    local path

    trap - EXIT

    if [[ -n $work ]]; then
        for path in "$work/boot" "$work/iso"; do
            if mountpoint -q "$path"; then
                umount "$path" || failed=1
            fi
        done

        if (( failed )); then
            printf 'Could not unmount temporary filesystems; leaving %s intact.\n' \
                "$work" >&2
            status=1
        else
            rm -rf -- "$work"
        fi
    fi

    exit "$status"
}

# Register cleanup, error reporting, and signal handlers.
configure_traps() {
    trap cleanup EXIT
    trap 'printf "\nInstallation failed at line %s. Do not boot the target until installation succeeds.\n" "$LINENO" >&2' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# Require root privileges, an interactive terminal, and supporting commands.
check_requirements() {
    local cmd
    local -a commands=(
        curl lsblk blkid blockdev parted partprobe udevadm
        mkfs.ext2 wipefs mount umount mountpoint findmnt readlink
        awk stat mktemp sync rm mkdir sleep cp cat
    )

    (( EUID == 0 )) || die 'Run with sudo bash install-bios.sh.'
    [[ -t 0 && -t 1 ]] || die 'An interactive terminal is required.'

    for cmd in "${commands[@]}"; do
        command -v "$cmd" >/dev/null || die "Missing command: $cmd"
    done
}

# Locate a GRUB installer and its legacy BIOS modules.
find_grub() {
    local dir
    local -a module_dirs=(
        /usr/lib/grub/i386-pc
        /usr/lib/grub2/i386-pc
        /usr/share/grub/i386-pc
        /usr/share/grub2/i386-pc
    )

    if command -v grub-install >/dev/null; then
        grub_install=$(command -v grub-install)
    elif command -v grub2-install >/dev/null; then
        grub_install=$(command -v grub2-install)
    else
        die 'Install GRUB tools and the i386-pc (BIOS) modules first.'
    fi

    for dir in "${module_dirs[@]}"; do
        if [[ -f $dir/modinfo.sh ]]; then
            bios_modules=$dir
            break
        fi
    done

    [[ -n $bios_modules ]] ||
        die 'GRUB BIOS modules missing (Debian: grub-pc-bin; Fedora: grub2-pc-modules).'
}

# Explain the destructive operation and select a supported whole disk.
select_disk() {
    say 'Lightwhale · BIOS disk setup'
    printf '%s\n' \
        'This erases the ENTIRE selected disk, including every existing partition.' \
        'Boot the result in legacy BIOS / CSM mode, not UEFI-only mode.' \
        'On first boot Lightwhale will format its data partition automatically.'
    printf '\n'

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
    local node name mounts holder

    [[ $(blockdev --getro "$device") == 0 ]] ||
        die 'The disk is read-only.'

    mounts=$(lsblk -nr -o MOUNTPOINTS "$device")
    [[ -z ${mounts//[[:space:]]/} ]] ||
        die 'Target has mounted filesystems or active swap. Unmount/disable them first.'

    while IFS= read -r node; do
        name=${node##*/}

        for holder in /sys/class/block/"$name"/holders/*; do
            [[ ! -e $holder ]] ||
                die "Target is in use by ${holder##*/} (RAID/LVM/device mapper)."
        done

        if findmnt -rn -S "$node" >/dev/null; then
            die "Target is mounted: $node"
        fi
    done < <(lsblk -nrpo NAME "$device")
}

# Prompt for an HTTPS ISO URL and download it into a temporary workspace.
download_iso() {
    printf '\nISO HTTPS URL [https://lightwhale.asklandd.dk/download/lightwhale-latest-x86.iso]: '
    IFS= read -r url
    url=${url:-https://lightwhale.asklandd.dk/download/lightwhale-latest-x86.iso}

    [[ $url == https://* ]] || die 'Use an HTTPS download URL.'

    work=$(mktemp -d /var/tmp/lightwhale-install.XXXXXXXX)
    mkdir "$work/iso" "$work/boot"

    say 'Downloading and inspecting ISO before touching the disk'
    printf '%sTemporary download: %s%s\n' \
        "$dim" "$work/lightwhale.iso" "$reset"

    curl --fail --location \
        --proto '=https' \
        --proto-redir '=https' \
        --retry 3 \
        --connect-timeout 30 \
        --progress-bar \
        --output "$work/lightwhale.iso" \
        "$url"
}

# Validate the ISO contents and extract its required RAM disk size.
inspect_iso() {
    local file rootfs_bytes
    local -a required_files=(
        boot/lightwhale-kernel
        boot/lightwhale-rootfs
        boot/grub/grub.cfg
    )

    mount -t iso9660 -o loop,ro,nosuid,nodev,noexec \
        "$work/lightwhale.iso" "$work/iso"

    for file in "${required_files[@]}"; do
        [[ -s $work/iso/$file ]] ||
            die "Not a supported Lightwhale ISO: missing $file"
    done

    ramdisk_kb=$(awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^ramdisk_size=[0-9]+$/) {
                    sub(/^ramdisk_size=/, "", $i)
                    print $i
                    exit
                }
            }
        }
    ' "$work/iso/boot/grub/grub.cfg")

    [[ $ramdisk_kb =~ ^[0-9]+$ ]] ||
        die 'ISO has no numeric ramdisk_size in its GRUB configuration.'

    rootfs_bytes=$(stat -c %s "$work/iso/boot/lightwhale-rootfs")
    (( ramdisk_kb >= (rootfs_bytes + 1023) / 1024 )) ||
        die 'ISO ramdisk_size is smaller than its root filesystem.'

    umount "$work/iso"
}

# Size the boot partition and ensure sufficient space remains for persistence.
calculate_layout() {
    local iso_bytes disk_bytes

    iso_bytes=$(stat -c %s "$work/lightwhale.iso")
    boot_mib=$(( (iso_bytes + 1048575) / 1048576 + 512 ))

    if (( boot_mib < 2048 )); then
        boot_mib=2048
    fi

    boot_end=$((3 + boot_mib))
    disk_bytes=$(blockdev --getsize64 "$device")

    (( disk_bytes / 1048576 > boot_end + 1025 )) ||
        die 'Disk too small: need room for the ISO boot partition plus at least 1 GiB of data.'
}

# Require explicit erasure confirmation and recheck the selected disk.
confirm_erasure() {
    local confirmation

    say "Proposed layout: $device"
    printf '  Partition 1   2 MiB       BIOS GRUB embedding area\n'
    printf '  Partition 2   %s MiB    ext2; /iso/lightwhale.iso and GRUB\n' "$boot_mib"
    printf '  Partition 3   remainder   Linux data; name lightwhale-please-format-me\n'
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

# Replace the partition table with BIOS embedding, boot, and data partitions.
create_partitions() {
    parted -s -a optimal "$device" -- \
        mklabel gpt \
        mkpart BIOS-GRUB 1MiB 3MiB \
        set 1 bios_grub on \
        mkpart LIGHTWHALE-BOOT ext2 3MiB "${boot_end}MiB" \
        mkpart lightwhale-please-format-me ext4 "${boot_end}MiB" 100%

    partprobe "$device"
    udevadm settle
}

# Wait for the kernel to expose the new partitions and resolve their device paths.
find_partitions() {
    local attempt

    for attempt in {1..10}; do
        boot_part=$(
            lsblk -nrpo NAME,PARTLABEL "$device" |
                awk '$2 == "LIGHTWHALE-BOOT" { print $1 }'
        )
        data_part=$(
            lsblk -nrpo NAME,PARTLABEL "$device" |
                awk '$2 == "lightwhale-please-format-me" { print $1 }'
        )

        if [[ -b $boot_part && -b $data_part ]]; then
            break
        fi

        sleep 1
    done

    [[ -b $boot_part && -b $data_part ]] ||
        die 'New partition devices did not appear.'
}

# Clear stale data signatures and create and mount the ext2 boot filesystem.
prepare_filesystems() {
    wipefs --all "$data_part"
    mkfs.ext2 -F -L LWBOOT "$boot_part"

    mount -o nosuid,nodev "$boot_part" "$work/boot"
    mkdir -p "$work/boot/iso" "$work/boot/boot/grub"
}

# Write a GRUB menu that boots the ISO using its filesystem UUID and RAM disk size.
write_grub_config() {
    local boot_uuid

    boot_uuid=$(blkid -s UUID -o value "$boot_part")
    [[ $boot_uuid =~ ^[0-9a-fA-F-]+$ ]] ||
        die 'Could not determine boot filesystem UUID.'

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
    linux (loop)/boot/lightwhale-kernel root=/dev/ram0 ramdisk_size=$ramdisk_kb console=tty0 consoleblank=300
    initrd (loop)/boot/lightwhale-rootfs
}
EOF
}

# Copy the ISO as a file and install legacy BIOS GRUB onto the selected disk.
install_bootloader() {
    cp -- "$work/lightwhale.iso" "$work/boot/iso/lightwhale.iso"
    write_grub_config

    "$grub_install" \
        --target=i386-pc \
        --directory="$bios_modules" \
        --boot-directory="$work/boot/boot" \
        --modules='part_gpt ext2 loopback iso9660 search_fs_uuid linux' \
        --recheck \
        "$device"
}

# Verify that the data partition opts into Lightwhale first-boot formatting.
verify_data_partition() {
    [[ $(lsblk -dnro PARTLABEL "$data_part") == lightwhale-please-format-me ]] ||
        die 'Wrong data partition name.'

    [[ $(lsblk -dnro PARTTYPE "$data_part") == 0fc63daf-8483-4772-8e79-3d69d8477de4 ]] ||
        die 'Wrong data partition type.'

    printf 'Ready: %s (Lightwhale will format it; no raw magic header is needed).\n' \
        "$data_part"
}

# Display boot instructions, persistence warnings, and upgrade guidance.
print_completion() {
    printf 'Eject the VPS rescue mode / eject the live ISO and restart.\n'
    printf 'Upon first boot, login with `op` / `opsecret` and immediately change password with `passwd`.\n\n'
    printf 'Future upgrades: mount your startup partition (ie. /dev/sda2) to /mnt/startup, replace /mnt/startup/iso/lightwhale.iso, and update ramdisk_size in /mnt/startup/boot/grub/grub.cfg to the output of `echo $((($(stat -c '%s' /mnt/iso/boot/lightwhale-rootfs) + 1023)/1024))` after `sudo mount -o loop new-lightwhale.iso /mnt/iso`.'
}

# Run preflight checks, obtain confirmation, and perform the installation.
main() {
    parse_arguments "$@"
    configure_output
    configure_traps

    check_requirements
    find_grub
    select_disk
    check_disk_idle
    initial_identity=$(lsblk -dnbo MAJ:MIN,SIZE "$device")

    download_iso
    inspect_iso
    calculate_layout
    confirm_erasure

    step 1 'Creating GPT and BIOS boot partitions'
    create_partitions
    find_partitions
    prepare_filesystems

    step 2 'Writing ISO and installing BIOS GRUB'
    install_bootloader

    step 3 'Checking the data partition opt-in'
    verify_data_partition
    sync
    umount "$work/boot"

    step 4 'Installation complete'
    print_completion
}

main "$@"
