#!/usr/bin/env bash

set -eu

usage() {
  cat << EOF
USAGE:
  ${0} <OPTIONS>
OPTIONS:
  --disk    Path of disk
EOF
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
elif [[ "${1}" == '--disk' ]]; then
  readonly DISK="${2}"
fi

readonly TARBALL_DIR='https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-systemd'

STAGE_FILE=$(curl -sL "${TARBALL_DIR}" | grep 'tar.xz"' | awk -F '"' '{print $8}')
readonly STAGE_FILE

BUILD_JOBS=$(($(nproc) + 1))
readonly BUILD_JOBS

mkfs.vfat -F 32 "${DISK}1"
mkfs.ext4 "${DISK}2"

mount "${DISK}2" /mnt/gentoo
mount -m -o fmask=0077,dmask=0077 "${DISK}1" /mnt/gentoo/boot

cd /mnt/gentoo
wget "${TARBALL_DIR}/${STAGE_FILE}"
tar xpvf "${STAGE_FILE}" --xattrs-include='*.*' --numeric-owner

cd /root
\cp -a /mnt/gentoo/etc/portage/make.conf{,.org}
\cp -a /root/gentoo-setup-main/minimal_make.conf /etc/portage/make.conf
\cp -a /root/gentoo-setup-main/package.{use,license} /mnt/gentoo/etc/portage

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

chroot /mnt/gentoo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
chroot /mnt/gentoo emerge-webrsync
chroot /mnt/gentoo emaint sync -a
chroot /mnt/gentoo eselect news read

chroot /mnt/gentoo emerge -uDN @world
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

cp -a /root/gentoo-setup-main/gentoo_kernel_conf /mnt/gentoo/usr/src/linux/.config
chroot /mnt/gentoo bash -c "cd /usr/src/linux && make -j${BUILD_JOBS} && make modules_install"
chroot /mnt/gentoo bash -c 'cd /usr/src/linux && make install'

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
rm /mnt/gentoo/stage3-*.tar.xz
