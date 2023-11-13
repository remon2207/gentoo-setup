#!/usr/bin/env bash

set -eu

usage() {
  cat << EOF
USAGE:
  ${0} <OPTIONS>
OPTIONS:
  disk
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

readonly TARBALL_DIR='https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-systemd'

STAGE_FILE=$(curl -sL "${TARBALL_DIR}" | grep 'tar.xz"' | awk -F '"' '{print $8}')
readonly STAGE_FILE

readonly DISK="${1}"

mkfs.ext4 "${DISK}1"
mkfs.ext4 "${DISK}2"

mount "${DISK}1" /mnt/gentoo
mount -m -o fmask=0077,dmask=0077 /dev/sdd1 /mnt/gentoo/boot
mount -m "${DISK}2" /mnt/gentoo/home

cd /mnt/gentoo
wget "${TARBALL_DIR}/${STAGE_FILE}"
tar xpvf "${STAGE_FILE}" --xattrs-include='*.*' --numeric-owner

cd /root
\cp -a /root/gentoo-setup-main/{make.conf,package.use,package.license} /mnt/gentoo/etc/portage

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
chroot /mnt/gentoo emerge --sync --quiet
chroot /mnt/gentoo eselect news read

chroot /mnt/gentoo emerge -vuDN @world
chroot /mnt/gentoo emerge app-editors/neovim
chroot /mnt/gentoo emerge -c

chroot /mnt/gentoo ln -sv /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
chroot /mnt/gentoo sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
chroot /mnt/gentoo sed -i 's/#ja_JP.UTF-8 UTF-8/ja_JP.UTF-8 UTF-8/' /etc/locale.gen
chroot /mnt/gentoo locale-gen
chroot /mnt/gentoo eselect locale set 4

env-update
source /mnt/gentoo/etc/profile

chroot /mnt/gentoo emerge sys-kernel/{linux-firmware,gentoo-sources,dracut} sys-firmware/intel-microcode
chroot /mnt/gentoo eselect kernel set 1

cp -a /root/gentoo-setup-main/kernel_config /mnt/gentoo/usr/src/linux/.config
cd /mnt/gentoo/usr/src/linux
chroot /mnt/gentoo make -j13
chroot /mnt/gentoo make modules_install
chroot /mnt/gentoo make install

dracut --kver "$(uname -r)-gentoo"

chroot /mnt/gentoo emerge -vuDN @world
chroot /mnt/gentoo emerge -c

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

chroot /mnt/gentoo passwd
chroot /mnt/gentoo systemd-machine-id-setup
chroot /mnt/gentoo systemd-firstboot --prompt
chroot /mnt/gentoo systemctl preset-all

chroot /mnt/gentoo bootctl install

chroot /mnt/gentoo useradd -m -G wheel -s /bin/bash remon
passwd remon
rm /mnt/gentoo/stage3-*.tar.xz
