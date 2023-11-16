#!/usr/bin/env bash

set -eu

usage() {
  cat << EOF
USAGE:
  ${0} --disk <disk> --gpu <nvidia | amd>
OPTIONS:
  --disk    Path of disk
  --gpu     [nvidia, amd]
EOF
}

if [[ $# -ne 4 ]]; then
  usage
  exit 1
elif [[ "${1}" == '--disk' ]] && [[ "${3}" == '--gpu' ]]; then
  readonly DISK="${2}"
  readonly GPU="${4}"
fi

readonly TARBALL_DIR='https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-systemd'

STAGE_FILE=$(curl -sL "${TARBALL_DIR}" | grep 'tar.xz"' | awk -F '"' '{print $8}')
readonly STAGE_FILE

BUILD_JOBS=$(($(nproc) + 1))
readonly BUILD_JOBS

NET_INTERFACE=$(ip -br link show | awk 'NR==2 {print $1}')
readonly NET_INTERFACE

WIRED_NETWORK=$(
  cat << EOF
[Match]
Name=${NET_INTERFACE}

[Network]
DHCP=yes
DNS=8.8.8.8
DNS=8.8.4.4
EOF
)
readonly WIRED_NETWORK

SCRIPT_DIR=$(
  cd "$(dirname "${0}")"
  pwd
)
readonly SCRIPT_DIR

if [[ "${GPU}" == 'nvidia' ]]; then
  readonly ENVIRONMENT="GTK_IM_MODULE='fcitx5'
QT_IM_MODULE='fcitx5'
XMODIFIERS='@im=fcitx5'

LIBVA_DRIVER_NAME='nvidia'
VDPAU_DRIVER='nvidia'"
elif [[ "${GPU}" == 'amd' ]]; then
  readonly ENVIRONMENT="GTK_IM_MODULE='fcitx5'
QT_IM_MODULE='fcitx5'
XMODIFIERS='@im=fcitx5'

LIBVA_DRIVER_NAME='radeonsi'
VDPAU_DRIVER='radeonsi'"
fi

gdisk "${DISK}"

mkfs.vfat -F 32 "${DISK}1"
mkfs.ext4 "${DISK}2"

mount "${DISK}2" /mnt/gentoo
mount -m -o fmask=0077,dmask=0077 "${DISK}1" /mnt/gentoo/boot

cd /mnt/gentoo
wget "${TARBALL_DIR}/${STAGE_FILE}"
tar xpvf "${STAGE_FILE}" --xattrs-include='*.*' --numeric-owner

\cp -a "${SCRIPT_DIR}"/{make.conf,package.{use,license,accept_keywords}} /mnt/gentoo/etc/portage

mkdir /mnt/gentoo/etc/portage/repos.conf
cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
cp -L /etc/resolv.conf /mnt/gentoo/etc/

mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

source /mnt/gentoo/etc/profile

chroot /mnt/gentoo emerge-webrsync
chroot /mnt/gentoo emaint sync -a
chroot /mnt/gentoo eselect news read

FEATURES='-ccache' chroot /mnt/gentoo emerge dev-util/ccache
chroot /mnt/gentoo emerge app-portage/cpuid2cpuflags
if [[ "${GPU}" == 'nvidia' ]]; then
  chroot /mnt/gentoo emerge media-libs/nvidia-vaapi-driver
fi

CPU_FLAGS=$(chroot /mnt/gentoo cpuid2cpuflags | sed 's/^CPU_FLAGS_X86: //g')
readonly CPU_FLAGS

chroot /mnt/gentoo sed -i "s/^# CPU_FLAGS_X86=/CPU_FLAGS_X86=\"${CPU_FLAGS}\"/" /etc/portage/make.conf
chroot /mnt/gentoo emerge -uDN @world
chroot /mnt/gentoo emerge app-editors/neovim
chroot /mnt/gentoo emerge --depclean

chroot /mnt/gentoo ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
chroot /mnt/gentoo sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
chroot /mnt/gentoo sed -i 's/#ja_JP.UTF-8 UTF-8/ja_JP.UTF-8 UTF-8/' /etc/locale.gen
chroot /mnt/gentoo locale-gen
chroot /mnt/gentoo eselect locale set 4

chroot /mnt/gentoo env-update
source /mnt/gentoo/etc/profile

chroot /mnt/gentoo emerge sys-kernel/{linux-firmware,gentoo-sources,dracut} sys-firmware/intel-microcode
chroot /mnt/gentoo eselect kernel set 1

cp -a "${SCRIPT_DIR}/gentoo_kernel_conf" /mnt/gentoo/usr/src/linux/.config
chroot /mnt/gentoo bash -c "cd /usr/src/linux && make oldconfig"
chroot /mnt/gentoo bash -c "cd /usr/src/linux && make -j${BUILD_JOBS} && make modules_install && make install"
chroot /mnt/gentoo dracut --kver "$(uname -r | awk -F '-' '{print $1}')-gentoo" --no-kernel

chroot /mnt/gentoo emerge -uDN @world
chroot /mnt/gentoo emerge --depclean

BOOT_PARTUUID=$(blkid -s PARTUUID -o value "${DISK}1")
readonly BOOT_PARTUUID

ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${DISK}2")
readonly ROOT_PARTUUID

FSTAB=$(
  cat << EOF
PARTUUID=${BOOT_PARTUUID} /boot vfat defaults,noatime,fmask=0077,dmask=0077 0 2
PARTUUID=${ROOT_PARTUUID} /     ext4 defaults,noatime                       0 1
EOF
)
readonly FSTAB

echo "${FSTAB}" >> /mnt/gentoo/etc/fstab
echo 'virtualbox' > /mnt/gentoo/etc/hostname
echo "${ENVIRONMENT}" >> /mnt/gentoo/etc/environment
echo "${WIRED_NETWORK}" >> /mnt/gentoo/etc/systemd/network/20-wired.network

chroot /mnt/gentoo sed -i 's/^#NTP=/NTP=ntp.nict.jp/' /etc/systemd/timesyncd.conf
chroot /mnt/gentoo sed -i 's/^#FallbackNTP=.*/FallbackNTP=ntp1.jst.mfeed.ad.jp ntp2.jst.mfeed.ad.jp ntp3.jst.mfeed.ad.jp/' /etc/systemd/timesyncd.conf

chroot /mnt/gentoo systemd-machine-id-setup
chroot /mnt/gentoo systemd-firstboot --keymap us
chroot /mnt/gentoo systemctl preset-all
chroot /mnt/gentoo bootctl install
chroot /mnt/gentoo useradd -m -G wheel -s /bin/bash virt
echo '====================================================='
echo 'Password of User'
echo '====================================================='
chroot /mnt/gentoo passwd virt
echo '====================================================='
echo 'Password of root'
echo '====================================================='
chroot /mnt/gentoo passwd

VMLINUZ=$(find /mnt/gentoo/boot/vmlinuz*gentoo* | awk -F '/' '{print $5}')
readonly VMLINUZ

UCODE=$(find /mnt/gentoo/boot/*-uc* | awk -F '/' '{print $5}')
readonly UCODE

INITRAMFS=$(find /mnt/gentoo/boot/initramfs*gentoo* | awk -F '/' '{print $5}')
readonly INITRAMFS

LOADER_CONF=$(
  cat << EOF
timeout      10
console-mode max
editor       no
EOF
)
readonly LOADER_CONF

MACHINE_ID=$(cat /mnt/gentoo/etc/machine-id)
readonly MACHINE_ID

NVIDIA_CONF=$(
  cat << EOF
title      Gentoo
linux      /${VMLINUZ}
initrd     /${UCODE}
initrd     /${INITRAMFS}
machine-id ${MACHINE_ID}
options    root=PARTUUID=${ROOT_PARTUUID} rw loglevel=3 panic=180
EOF
)
readonly NVIDIA_CONF

echo "${LOADER_CONF}" >> /mnt/gentoo/boot/loader/loader.conf
echo "${NVIDIA_CONF}" >> /mnt/gentoo/boot/loader/entries/gentoo.conf

rm /mnt/gentoo/stage3-*.tar.xz
