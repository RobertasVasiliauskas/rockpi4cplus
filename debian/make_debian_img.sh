#!/bin/sh

set -e

main() {
    local media='mmc_2g.img'
    local hostname='rock4cp-arm64'
    local acct_uid='arch'
    local acct_pass='arch'
    local extra_pkgs='curl pciutils sudo unzip wget xxd xz-utils zip zstd'

    if is_param 'clean' "$@"; then
        rm -rf cache*/var
        rm -f "$media"*
        rm -rf "$mountpt"
        rm -rf rootfs
        echo '\nclean complete\n'
        exit 0
    fi

    check_installed 'wget' 'xz-utils'

    if [ -f "$media" ]; then
        read -p "file $media exists, overwrite? <y/N> " yn
        if ! [ "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
            echo 'exiting...'
            exit 0
        fi
    fi

    local compress=$(is_param 'nocomp' "$@" || [ -b "$media" ] && echo false || echo true)

    if $compress && [ -f "$media.xz" ]; then
        read -p "file $media.xz exists, overwrite? <y/N> " yn
        if ! [ "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
            echo 'exiting...'
            exit 0
        fi
    fi

    print_hdr "downloading files"
    local cache="cache.arch"

    # Arch Linux ARM root filesystem
    local arch_rootfs=$(download "$cache" 'http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz')
    local arch_rootfs_sha='d41d8cd98f00b204e9800998ecf8427e'
    [ "$arch_rootfs_sha" = $(sha256sum "$arch_rootfs" | cut -c1-64) ] || { echo "invalid hash for $arch_rootfs"; exit 5; }

    # u-boot
    local uboot_spl=$(download "$cache" 'https://github.com/inindev/rockpi-4c-plus/releases/download/v12.0/idbloader.img')
    [ -f "$uboot_spl" ] || { echo "unable to fetch $uboot_spl"; exit 4; }
    local uboot_itb=$(download "$cache" 'https://github.com/inindev/rockpi-4c-plus/releases/download/v12.0/u-boot.itb')
    [ -f "$uboot_itb" ] || { echo "unable to fetch: $uboot_itb"; exit 4; }

    # dtb
    local dtb=$(download "$cache" "https://github.com/inindev/rockpi-4c-plus/releases/download/v12.0/rk3399-rock-4c-plus.dtb")
    [ -f "$dtb" ] || { echo "unable to fetch $dtb"; exit 4; }

    # bluetooth firmware
    local bfw=$(download "$cache" 'https://github.com/murata-wireless/cyw-bt-patch/raw/master/BCM4345C0_003.001.025.0187.0366.1MW.hcd')
    local bfwsha='c903509c43baf812283fbd10c65faab3b0735e09bd57c5a9e9aa97cf3f274d3b'
    [ "$bfwsha" = $(sha256sum "$bfw" | cut -c1-64) ] || { echo "invalid hash for $bfw"; exit 5; }

    if [ ! -b "$media" ]; then
        print_hdr "creating image file"
        make_image_file "$media"
    fi

    print_hdr "partitioning media"
    parition_media "$media"

    print_hdr "formatting media"
    format_media "$media"

    print_hdr "mounting media"
    mount_media "$media"

    print_hdr "configuring files"
    mkdir "$mountpt/etc"
    echo 'link_in_boot = 1' > "$mountpt/etc/kernel-img.conf"
    echo 'do_symlinks = 0' >> "$mountpt/etc/kernel-img.conf"

    local mdev="$(findmnt -no source "$mountpt")"
    local uuid="$(blkid -o value -s UUID "$mdev")"
    echo "$(file_fstab $uuid)\n" > "$mountpt/etc/fstab"

    print_hdr "installing firmware"
    mkdir -p "$mountpt/usr/lib/firmware"
    local lfwn=$(basename "$lfw")
    local lfwbn="${lfwn%%.*}"
    tar -C "$mountpt/usr/lib/firmware" --strip-components=1 --wildcards -xavf "$lfw" "$lfwbn/rockchip" "$lfwbn/rtl_nic" "$lfwbn/brcm/brcmfmac43455-sdio.AW-CM256SM.txt" "$lfwbn/cypress/cyfmac43455-sdio.*"

    ln -svf "brcmfmac43455-sdio.AW-CM256SM.txt" "$mountpt/usr/lib/firmware/brcm/brcmfmac43455-sdio.radxa,rock-4c-plus.txt"
    ln -svf "../cypress/cyfmac43455-sdio.bin" "$mountpt/usr/lib/firmware/brcm/brcmfmac43455-sdio.radxa,rock-4c-plus.bin"
    ln -svf "../cypress/cyfmac43455-sdio.clm_blob" "$mountpt/usr/lib/firmware/brcm/brcmfmac43455-sdio.radxa,rock-4c-plus.clm_blob"

    local bfwn=$(basename "$bfw")
    cp -v "$bfw" "$mountpt/usr/lib/firmware/brcm"
    ln -svf "$bfwn" "$mountpt/usr/lib/firmware/brcm/BCM4345C0.radxa,rock-4c-plus.hcd"

    install -vm 644 "$dtb" "$mountpt/boot"

    print_hdr "installing root filesystem from Arch Linux ARM"
    tar -xpf "$arch_rootfs" -C "$mountpt"

    echo "$(file_locale_cfg)\n" > "$mountpt/etc/locale.conf"

    # Install and enable SSH
    print_hdr "installing and enabling SSH"
    arch-chroot "$mountpt" pacman -Sy --noconfirm openssh
    arch-chroot "$mountpt" systemctl enable sshd

    sed -i '/alias.ll=/s/^#*\s*//' "$mountpt/etc/skel/.bashrc"
    sed -i '/export.LS_OPTIONS/s/^#*\s*//' "$mountpt/root/.bashrc"
    sed -i '/eval.*dircolors/s/^#*\s*//' "$mountpt/root/.bashrc"
    sed -i '/alias.l.=/s/^#*\s*//' "$mountpt/root/.bashrc"

    echo $hostname > "$mountpt/etc/hostname"
    sed -i "s/127.0.0.1\tlocalhost/127.0.0.1\tlocalhost\n127.0.1.1\t$hostname/" "$mountpt/etc/hosts"

    print_hdr "creating user account"
    arch-chroot "$mountpt" useradd -m "$acct_uid" -s '/bin/bash'
    arch-chroot "$mountpt" sh -c "echo $acct_uid:$acct_pass | chpasswd"
    arch-chroot "$mountpt" passwd -e "$acct_uid"
    (umask 377 && echo "$acct_uid ALL=(ALL) NOPASSWD: ALL" > "$mountpt/etc/sudoers.d/$acct_uid")

    print_hdr "installing rootfs expansion script to /etc/rc.local"
    install -Dvm 754 'files/rc.local' "$mountpt/etc/rc.local"

    rm -fv "$mountpt/etc/systemd/system/sshd.service"
    rm -fv "$mountpt/etc/systemd/system/multi-user.target.wants/ssh.service"
    rm -fv "$mountpt/etc/ssh/ssh_host_"*

    rm -fv "$mountpt/etc/machine-id"

    [ -b "$media" ] || fstrim -v "$mountpt"

    umount "$mountpt"
    rm -rf "$mountpt"

    print_hdr "installing u-boot"
    dd bs=4K seek=8 if="$uboot_spl" of="$media" conv=notrunc
    dd bs=4K seek=2048 if="$uboot_itb" of="$media" conv=notrunc,fsync

    if $compress; then
        print_hdr "compressing image file"
        xz -z8v "$media"
        echo "\n${cya}compressed image is now ready${rst}"
        echo "\n${cya}copy image to target media:${rst}"
        echo "  ${cya}sudo sh -c 'xzcat $media.xz > /dev/sdX && sync'${rst}"
    elif [ -b "$media" ]; then
        echo "\n${cya}media is now ready${rst}"
    else
        echo "\n${cya}image is now ready${rst}"
        echo "\n${cya}copy image to media:${rst}"
        echo "  ${cya}sudo sh -c 'cat $media > /dev/sdX && sync'${rst}"
    fi
    echo
}

make_image_file() {
    local filename="$1"
    rm -f "$filename"*
    local size="$(echo "$filename" | sed -rn 's/.*mmc_([[:digit:]]+[m|g])\.img$/\1/p')"
    truncate -s "$size" "$filename"
}

parition_media() {
    local media="$1"

  cat <<-EOF | sfdisk "$media"
	label: gpt
	unit: sectors
	first-lba: 2048
	part1: start=32768, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=rootfs
	EOF
    sync
}

format_media() {
    local media="$1"
    local partnum="${2:-1}"

    if [ -b "$media" ]; then
        local rdn="$(basename "$media")"
        local sbpn="$(echo /sys/block/${rdn}/${rdn}*${partnum})"
        local part="/dev/$(basename "$sbpn")"
        mkfs.ext4 -L rootfs -vO metadata_csum_seed "$part" && sync
    else
        local lodev="$(losetup -f)"
        losetup -vP "$lodev" "$media" && sync
        mkfs.ext4 -L rootfs -vO metadata_csum_seed "${lodev}p${partnum}" && sync
        losetup -vd "$lodev" && sync
    fi
}

mount_media() {
    local media="$1"
    local partnum="1"

    if [ -d "$mountpt" ]; then
        mountpoint -q "$mountpt/var/cache" && umount "$mountpt/var/cache"
        mountpoint -q "$mountpt/var/lib/apt/lists" && umount "$mountpt/var/lib/apt/lists"
        mountpoint -q "$mountpt" && umount "$mountpt"
    else
        mkdir -p "$mountpt"
    fi

    local success_msg
    if [ -b "$media" ]; then
        local rdn="$(basename "$media")"
        local sbpn="$(echo /sys/block/${rdn}/${rdn}*${partnum})"
        local part="/dev/$(basename "$sbpn")"
        mount -n "$part" "$mountpt"
        success_msg="partition ${cya}$part${rst} successfully mounted on ${cya}$mountpt${rst}"
    elif [ -f "$media" ]; then
        mount -no loop,offset=16M "$media" "$mountpt"
        success_msg="media ${cya}$media${rst} partition 1 successfully mounted on ${cya}$mountpt${rst}"
    else
        echo "file not found: $media"
        exit 4
    fi

    if [ ! -d "$mountpt/lost+found" ]; then
        echo 'failed to mount the image file'
        exit 3
    fi

    echo "$success_msg"
}

check_mount_only() {
    local item img flag=false
    for item in "$@"; do
        case "$item" in
            mount) flag=true ;;
            *.img) img=$item ;;
            *.img.xz) img=$item ;;
        esac
    done
    ! $flag && return

    if [ ! -f "$img" ]; then
        if [ -z "$img" ]; then
            echo "no image file specified"
        else
            echo "file not found: ${red}$img${rst}"
        fi
        exit 3
    fi

    case "$img" in
        *.xz)
            local tmp=$(basename "$img" .xz)
            if [ -f "$tmp" ]; then
                echo "compressed file ${bld}$img${rst} was specified but uncompressed file ${bld}$tmp${rst} exists..."
                echo -n "mount ${bld}$tmp${rst}"
                read -p " instead? <Y/n> " yn
                if ! [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
                    echo 'exiting...'
                    exit 0
                fi
                img=$tmp
            else
                echo -n "compressed file ${bld}$img${rst} was specified"
                read -p ', decompress to mount? <Y/n>' yn
                if ! [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
                    echo 'exiting...'
                    exit 0
                fi
                xz -dk "$img"
                img=$(basename "$img" .xz)
            fi
            ;;
    esac

    echo "mounting file ${yel}$img${rst}..."
    mount_media "$img"
    trap - EXIT INT QUIT ABRT TERM
    echo "media mounted, use ${grn}sudo umount $mountpt${rst} to unmount"

    exit 0
}

on_exit() {
    if mountpoint -q "$mountpt"; then
        mountpoint -q "$mountpt/var/cache" && umount "$mountpt/var/cache"
        mountpoint -q "$mountpt/var/lib/apt/lists" && umount "$mountpt/var/lib/apt/lists"

        read -p "$mountpt is still mounted, unmount? <Y/n> " yn
        if [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
            echo "unmounting $mountpt"
            umount "$mountpt"
            sync
            rm -rf "$mountpt"
        fi
    fi
}
mountpt='rootfs'
trap on_exit EXIT INT QUIT ABRT TERM

file_fstab() {
  local uuid="$1"

  cat <<-EOF
	# <device>					<mount>	<type>	<options>		<dump> <pass>
	UUID=$uuid	/	ext4	errors=remount-ro	0      1
	EOF
}

file_locale_cfg() {
	cat <<-EOF
	LANG="en_US.UTF-8"
	EOF
}

download() {
    local cache="$1"
    local url="$2"

    [ -d "$cache" ] || mkdir -p "$cache"

    local filename="$(basename "$url")"
    local filepath="$cache/$filename"
    [ -f "$filepath" ] || wget "$url" -P "$cache"
    [ -f "$filepath" ] || exit 2

    echo "$filepath"
}

is_param() {
    local item match
    for item in "$@"; do
        if [ -z "$match" ]; then
            match="$item"
        elif [ "$match" = "$item" ]; then
            return 0
        fi
    done
    return 1
}

check_installed() {
    local item todo
    for item in "$@"; do
        dpkg -l "$item" 2>/dev/null | grep -q "ii  $item" || todo="$todo $item"
    done

    if [ ! -z "$todo" ]; then
        echo "this script requires the following packages:${bld}${yel}$todo${rst}"
        echo "   run: ${bld}${grn}sudo apt update && sudo apt -y install$todo${rst}\n"
        exit 1
    fi
}

print_hdr() {
    local msg="$1"
    echo "\n${h1}$msg...${rst}"
}

rst='\033[m'
bld='\033[1m'
red='\033[31m'
grn='\033[32m'
yel='\033[33m'
blu='\033[34m'
mag='\033[35m'
cya='\033[36m'
h1="${blu}==>${rst} ${bld}"

if [ 0 -ne $(id -u) ]; then
    echo 'this script must be run as root'
    echo "   run: ${bld}${grn}sudo sh $(basename "$0")${rst}\n"
    exit 9
fi

cd "$(dirname "$(realpath "$0")")"
check_mount_only "$@"
main "$@"