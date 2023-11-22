#!/usr/bin/env bash

set -eu

unalias cp rm

readonly DISK='/dev/sda'
BUILD_JOBS="$(("$(nproc)" + 1))" && readonly BUILD_JOBS
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)" && readonly SCRIPT_DIR
CPU_INFO="$(grep 'model name' /proc/cpuinfo | awk -F '[ (]' 'NR==1 {print $2}')" && readonly CPU_INFO

to_gentoo() { chroot /mnt/gentoo "${@}"; }

partitioning() {
  local -r EFI_PART_TYPE="$(sgdisk -L | grep 'ef00' | awk '{print $6,$7,$8}')"
  local -r NORMAL_PART_TYPE="$(sgdisk -L | grep '8300' | awk '{print $2,$3}')"

  sgdisk -Z "${DISK}"
  sgdisk -n 0::+512M -t 0:ef00 -c "0:${EFI_PART_TYPE}" "${DISK}"
  sgdisk -n 0:: -t 0:8300 -c "0:${NORMAL_PART_TYPE}" "${DISK}"

  mkfs.vfat -F 32 "${DISK}1"
  mkfs.ext4 "${DISK}2"

  mount "${DISK}2" /mnt/gentoo
  mount -m -o fmask=0077,dmask=0077 "${DISK}1" /mnt/gentoo/boot
}

tarball_extract() {
  local -r TARBALL_DIR='https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-systemd'
  local -r STAGE_FILE="$(curl -sL "${TARBALL_DIR}" | grep 'tar.xz"' | awk -F '"' '{print $8}')"

  cd /mnt/gentoo
  wget "${TARBALL_DIR}/${STAGE_FILE}"
  tar xpvf "${STAGE_FILE}" --xattrs-include='*.*' --numeric-owner
}

portage_configration() {
  cp -a "${SCRIPT_DIR}"/{make.conf,package.{use,license,accept_keywords}} /mnt/gentoo/etc/portage

  mkdir /mnt/gentoo/etc/portage/repos.conf
  cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
  cp -L /etc/resolv.conf /mnt/gentoo/etc

  case "${CPU_INFO}" in
  'Intel')
    echo 'sys-firmware/intel-microcode initramfs' > /mnt/gentoo/etc/portage/package.use/intel-microcode > /dev/null 2>&1
    rm -rf /mnt/gentoo/etc/portage/package.use/linux-firmware
    ;;
  'AMD')
    echo 'sys-kernel/linux-firmware initramfs' > /mnt/gentoo/etc/portage/package.use/linux-firmware > /dev/null 2>&1
    rm -rf /mnt/gentoo/etc/portage/package.use/intel-microcode
    ;;
  esac

  to_gentoo sed -i -e "s/^\(MAKEOPTS=\"-j\).*/\1${BUILD_JOBS}\"/" -e \
    's/^\(CPU_FLAGS_X86=\).*/# \1/' -e \
    's/^\(VIDEO_CARDS=\).*/\1"virtualbox"/' -e \
    's/^\(USE=".*\) pulseaudio/\1/' -e \
    's/^\(USE=".*\)nvenc /\1/' -e \
    's/^\(USE=".*\)nvidia /\1/' /etc/portage/make.conf
}

mounting() {
  mount --types proc /proc /mnt/gentoo/proc
  for dir in sys dev; do mount --rbind "/${dir}" "/mnt/gentoo/${dir}" && mount --make-rslave "/mnt/gentoo/${dir}"; done
  mount --bind /run /mnt/gentoo/run
  mount --make-slave /mnt/gentoo/run

  # shellcheck disable=SC1091
  . /mnt/gentoo/etc/profile
}

repository_update() {
  to_gentoo emerge-webrsync
  to_gentoo emaint sync -a
  to_gentoo eselect news read
}

profile_package_installation() {
  FEATURES='-ccache' to_gentoo emerge dev-util/ccache
  to_gentoo emerge app-portage/cpuid2cpuflags

  local -r CPU_FLAGS="$(to_gentoo cpuid2cpuflags | sed 's/^CPU_FLAGS_X86: //')"

  to_gentoo sed -i -e "s/^# \(CPU_FLAGS_X86=\)/\1\"${CPU_FLAGS}\"/" /etc/portage/make.conf
  to_gentoo emerge -uDN @world
  to_gentoo emerge app-editors/neovim
  to_gentoo emerge --depclean
}

localization() {
  to_gentoo ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
  to_gentoo sed -i -e 's/^#\(en_US.UTF-8 UTF-8\)/\1/' -e \
    's/^#\(ja_JP.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  to_gentoo locale-gen
  to_gentoo eselect locale set 4

  to_gentoo env-update
  # shellcheck disable=SC1091
  . /mnt/gentoo/etc/profile
}

kernel_installation() {
  to_gentoo emerge sys-kernel/{linux-firmware,gentoo-sources,dracut}

  [[ "${CPU_INFO}" == 'Intel' ]] && to_gentoo emerge sys-firmware/intel-microcode

  to_gentoo eselect kernel set 1

  cp -a "${SCRIPT_DIR}/kernel_conf" /mnt/gentoo/usr/src/linux/.config
  to_gentoo bash -c 'cd /usr/src/linux && make oldconfig && make menuconfig'
  to_gentoo bash -c "cd /usr/src/linux && make -j${BUILD_JOBS} && make modules_install && make install"
  to_gentoo dracut --kver "$(uname -r | awk -F '-' '{print $1}')-gentoo" --no-kernel

  to_gentoo emerge -uDN @world
  to_gentoo emerge --depclean
}

fstab_configration() {
  show_partuuid() { blkid -s PARTUUID -o value "${1}"; }

  local -r BOOT_PARTUUID="$(show_partuuid "${DISK}1")"
  ROOT_PARTUUID="$(show_partuuid "${DISK}2")" && readonly ROOT_PARTUUID

  local -r FSTAB="$(
    cat << EOF
PARTUUID=${BOOT_PARTUUID} /boot vfat defaults,noatime,fmask=0077,dmask=0077 0 2
PARTUUID=${ROOT_PARTUUID} /     ext4 defaults,noatime                       0 1
EOF
  )"

  echo "${FSTAB}" >> /mnt/gentoo/etc/fstab
}

systemd_configration() {
  to_gentoo systemd-machine-id-setup
  to_gentoo systemd-firstboot --keymap us
  to_gentoo systemctl preset-all
  to_gentoo bootctl install

  find_boot() { find /mnt/gentoo/boot "${@}"; }

  local -r MACHINE_ID="$(cat /mnt/gentoo/etc/machine-id)"
  local -r VMLINUZ="$(find_boot -name '*vmlinuz*gentoo' -type f | awk -F '/' '{print $5}')"
  local -r UCODE="$(find_boot -name '*uc*' -type f | awk -F '/' '{print $5}')"
  local -r INITRAMFS="$(find_boot -name '*initramfs*gentoo*' -type f | awk -F '/' '{print $5}')"

  local -r LOADER_CONF="$(
    cat << EOF
timeout      10
console-mode max
editor       no
EOF
  )"

  local -r ENTRY_CONF="$(
    cat << EOF
title      Gentoo
linux      /${VMLINUZ}
initrd     /${UCODE}
initrd     /${INITRAMFS}
machine-id ${MACHINE_ID}
options    root=PARTUUID=${ROOT_PARTUUID} rw loglevel=3 panic=180
EOF
  )"

  echo "${LOADER_CONF}" >> /mnt/gentoo/boot/loader/loader.conf
  echo "${ENTRY_CONF}" >> /mnt/gentoo/boot/loader/entries/gentoo.conf
}

user_setting() {
  local -r USER_NAME='virt'

  to_gentoo useradd -m -G wheel -s /bin/bash "${USER_NAME}"
  echo "${USER_NAME}:virt" | to_gentoo chpasswd
  echo 'root:root' | to_gentoo chpasswd
}

others_configration() {
  local -r NET_INTERFACE="$(ip -br link show | awk 'NR==2 {print $1}')"
  local -r WIRED_NETWORK="[Match]
Name=${NET_INTERFACE}

[Network]
DHCP=yes
DNS=8.8.8.8
DNS=8.8.4.4"

  # Network
  echo 'virtualbox' > /mnt/gentoo/etc/hostname
  echo "${WIRED_NETWORK}" >> /mnt/gentoo/etc/systemd/network/20-wired.network
  # Time sync
  to_gentoo sed -i -e 's/^#\(NTP=\)/\1ntp.nict.jp/' -e \
    's/^#\(FallbackNTP=\).*/\1ntp1.jst.mfeed.ad.jp ntp2.jst.mfeed.ad.jp ntp3.jst.mfeed.ad.jp/' /etc/systemd/timesyncd.conf

  to_gentoo emerge app-admin/sudo
  to_gentoo sed -e 's/^# \(%wheel ALL=(ALL:ALL) ALL\)/\1/' /etc/sudoers | EDITOR='tee' to_gentoo visudo &> /dev/null

  rm -rf /mnt/gentoo/stage3-*.tar.xz
}

main() {
  partitioning
  tarball_extract
  portage_configration
  mounting
  repository_update
  profile_package_installation
  localization
  kernel_installation
  fstab_configration
  systemd_configration
  user_setting
  others_configration
}

main "${@}"
