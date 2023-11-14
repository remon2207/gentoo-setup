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
DNS=192.168.1.202
EOF
)
readonly WIRED_NETWORK

SCRIPT_DIR=$(
  cd "$(dirname "${0}")"
  pwd
)

if [[ "${GPU}" == 'nvidia' ]]; then
  readonly ENVIRONMENT="GTK_IM_MODULE='fcitx5'
  QT_IM_MODULE='fcitx5'
  XMODIFIERS='@im=fcitx5'

  LIBVA_DRIVER_NAME='vdpau'
  VDPAU_DRIVER='nvidia'"
elif [[ "${GPU}" == 'amd' ]]; then
  readonly ENVIRONMENT="GTK_IM_MODULE='fcitx5'
  QT_IM_MODULE='fcitx5'
  XMODIFIERS='@im=fcitx5'

  LIBVA_DRIVER_NAME='radeonsi'
  VDPAU_DRIVER='radeonsi'"
fi

mkfs.ext4 "${DISK}1"

mount "${DISK}1" /mnt/gentoo
mount -m -o fmask=0077,dmask=0077 /dev/sdd1 /mnt/gentoo/boot
mount -m "${DISK}2" /mnt/gentoo/home

cd /mnt/gentoo
wget "${TARBALL_DIR}/${STAGE_FILE}"
tar xpvf "${STAGE_FILE}" --xattrs-include='*.*' --numeric-owner

\cp -a "${SCRIPT_DIR}"/{make.conf,package.{use,license}} /mnt/gentoo/etc/portage

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
chroot /mnt/gentoo bash -c "cd /usr/src/linux && make -j${BUILD_JOBS} && make modules_install && make install"
chroot /mnt/gentoo dracut --kver "$(uname -r | awk -F '-' '{print $1}')-gentoo" --no-kernel

chroot /mnt/gentoo emerge -uDN @world
chroot /mnt/gentoo emerge --depclean

BOOT_PARTUUID=$(blkid -s PARTUUID -o value /dev/sdd1)
readonly BOOT_PARTUUID

ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${DISK}1")
readonly ROOT_PARTUUID

HOME_PARTUUID=$(blkid -s PARTUUID -o value "${DISK}2")
readonly HOME_PARTUUID

FSTAB=$(
  cat << EOF
PARTUUID=${BOOT_PARTUUID} /boot vfat defaults,noatime,fmask=0077,dmask=0077 0 2
PARTUUID=${ROOT_PARTUUID} /     ext4 defaults,noatime                       0 1
PARTUUID=${HOME_PARTUUID} /home ext4 defaults,noatime                       0 2

# ramdisk
tmpfs /tmp               tmpfs rw,nodev,nosuid,noatime,size=4G,mode=1777                   0 0
tmpfs /var/tmp/portage   tmpfs rw,nodev,nosuid,noatime,size=8G                             0 0
tmpfs /home/remon/.cache tmpfs rw,nodev,nosuid,noatime,size=8G,mode=0755,uid=1000,gid=1000 0 0
EOF
)
readonly FSTAB

echo "${FSTAB}" >> /mnt/gentoo/etc/fstab
echo 'gentoo' > /mnt/gentoo/etc/hostname
echo "${ENVIRONMENT}" >> /mnt/gentoo/etc/environment
echo "${WIRED_NETWORK}" >> /mnt/gentoo/etc/systemd/network/20-wired.network

chroot /mnt/gentoo sed -i 's/^#NTP=/NTP=ntp.nict.jp/' /etc/systemd/timesyncd.conf
chroot /mnt/gentoo sed -i 's/^#FallbackNTP=/FallbackNTP=ntp1.jst.mfeed.ad.jp ntp2.jst.mfeed.ad.jp ntp3.jst.mfeed.ad.jp/' /etc/systemd/timesyncd.conf

chroot /mnt/gentoo systemd-machine-id-setup
chroot /mnt/gentoo systemd-firstboot --keymap us
chroot /mnt/gentoo systemctl preset-all
chroot /mnt/gentoo bootctl install
chroot /mnt/gentoo useradd -m -G wheel -s /bin/bash remon
echo '====================================================='
echo 'Password of User'
echo '====================================================='
chroot /mnt/gentoo passwd remon
echo '====================================================='
echo 'Password of root'
echo '====================================================='
chroot /mnt/gentoo passwd
rm /mnt/gentoo/stage3-*.tar.xz
