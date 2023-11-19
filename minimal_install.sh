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

if [[ ${#} -ne 4 ]]; then
  usage
  exit 1
elif [[ "${1}" == '--disk' ]] && [[ "${3}" == '--gpu' ]]; then
  readonly DISK="${2}"
  readonly GPU="${4}"
fi

BUILD_JOBS=$(($(nproc) + 1))
readonly BUILD_JOBS

SCRIPT_DIR=$(
  cd "$(dirname "${0}")"
  pwd
)
readonly SCRIPT_DIR

partitioning() {
  local -r EFI_PART_TYPE=$(sgdisk -L | grep 'ef00' | awk '{print $6,$7,$8}')
  local -r NORMAL_PART_TYPE=$(sgdisk -L | grep '8300' | awk '{print $2,$3}')

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
  local -r STAGE_FILE=$(curl -sL "${TARBALL_DIR}" | grep 'tar.xz"' | awk -F '"' '{print $8}')

  cd /mnt/gentoo
  wget "${TARBALL_DIR}/${STAGE_FILE}"
  tar xpvf "${STAGE_FILE}" --xattrs-include='*.*' --numeric-owner
}

portage_configration() {
  \cp -a "${SCRIPT_DIR}"/{make.conf,package.{use,license,accept_keywords}} /mnt/gentoo/etc/portage

  mkdir /mnt/gentoo/etc/portage/repos.conf
  cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
  cp -L /etc/resolv.conf /mnt/gentoo/etc/

  chroot /mnt/gentoo sed -i -e "s/^\(MAKEOPTS=\"-j\).*/\1${BUILD_JOBS}\"/" -e \
    's/^\(CPU_FLAGS_X86=\).*/# \1/' -e \
    's/^\(USE=".*\) pulseaudio/\1/' /etc/portage/make.conf
}

mounting() {
  mount --types proc /proc /mnt/gentoo/proc
  for dir in sys dev; do
    mount --rbind "/${dir}" "/mnt/gentoo/${dir}"
    mount --make-rslave "/mnt/gentoo/${dir}"
  done
  mount --bind /run /mnt/gentoo/run
  mount --make-slave /mnt/gentoo/run

  # shellcheck disable=SC1091
  source /mnt/gentoo/etc/profile
}

repository_update() {
  chroot /mnt/gentoo emerge-webrsync
  chroot /mnt/gentoo emaint sync -a
  chroot /mnt/gentoo eselect news read
}

profile_package_installation() {
  FEATURES='-ccache' chroot /mnt/gentoo emerge dev-util/ccache
  chroot /mnt/gentoo emerge app-portage/cpuid2cpuflags

  [[ "${GPU}" == 'nvidia' ]] && chroot /mnt/gentoo emerge media-libs/nvidia-vaapi-driver

  local -r CPU_FLAGS=$(chroot /mnt/gentoo cpuid2cpuflags | sed 's/^CPU_FLAGS_X86: //')

  chroot /mnt/gentoo sed -i -e "s/^# \(CPU_FLAGS_X86=\)/\1\"${CPU_FLAGS}\"/" /etc/portage/make.conf
  chroot /mnt/gentoo emerge -uDN @world
  chroot /mnt/gentoo emerge app-editors/neovim
  chroot /mnt/gentoo emerge --depclean
}

localization() {
  chroot /mnt/gentoo ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
  chroot /mnt/gentoo sed -i -e 's/^#\(en_US.UTF-8 UTF-8\)/\1/' -e \
    's/^#\(ja_JP.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  chroot /mnt/gentoo locale-gen
  chroot /mnt/gentoo eselect locale set 4

  chroot /mnt/gentoo env-update
  # shellcheck disable=SC1091
  source /mnt/gentoo/etc/profile
}

kernel_installation() {
  chroot /mnt/gentoo emerge sys-kernel/{linux-firmware,gentoo-sources,dracut} sys-firmware/intel-microcode
  chroot /mnt/gentoo eselect kernel set 1

  cp -a "${SCRIPT_DIR}/kernel_conf" /mnt/gentoo/usr/src/linux/.config
  chroot /mnt/gentoo bash -c 'cd /usr/src/linux && make oldconfig'
  chroot /mnt/gentoo bash -c "cd /usr/src/linux && make -j${BUILD_JOBS} && make modules_install && make install"
  chroot /mnt/gentoo dracut --kver "$(uname -r | awk -F '-' '{print $1}')-gentoo" --no-kernel

  chroot /mnt/gentoo emerge -uDN @world
  chroot /mnt/gentoo emerge --depclean
}

fstab_configration() {
  local -r BOOT_PARTUUID=$(blkid -s PARTUUID -o value "${DISK}1")

  ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${DISK}2")
  readonly ROOT_PARTUUID

  local -r FSTAB=$(
    cat << EOF
PARTUUID=${BOOT_PARTUUID} /boot vfat defaults,noatime,fmask=0077,dmask=0077 0 2
PARTUUID=${ROOT_PARTUUID} /     ext4 defaults,noatime                       0 1
EOF
  )

  echo "${FSTAB}" >> /mnt/gentoo/etc/fstab
}

systemd_configration() {
  chroot /mnt/gentoo systemd-machine-id-setup
  chroot /mnt/gentoo systemd-firstboot --keymap us
  chroot /mnt/gentoo systemctl preset-all
  chroot /mnt/gentoo bootctl install

  local -r MACHINE_ID=$(cat /mnt/gentoo/etc/machine-id)
  local -r VMLINUZ=$(find /mnt/gentoo/boot -iname '*vmlinuz*gentoo' -type f | awk -F '/' '{print $5}')
  local -r UCODE=$(find /mnt/gentoo/boot -iname '*uc*' -type f | awk -F '/' '{print $5}')
  local -r INITRAMFS=$(find /mnt/gentoo/boot -iname '*initramfs*gentoo*' -type f | awk -F '/' '{print $5}')

  local -r LOADER_CONF=$(
    cat << EOF
timeout      10
console-mode max
editor       no
EOF
  )

  local -r ENTRY_CONF=$(
    cat << EOF
title      Gentoo
linux      /${VMLINUZ}
initrd     /${UCODE}
initrd     /${INITRAMFS}
machine-id ${MACHINE_ID}
options    root=PARTUUID=${ROOT_PARTUUID} rw loglevel=3 panic=180
EOF
  )

  echo "${LOADER_CONF}" >> /mnt/gentoo/boot/loader/loader.conf
  echo "${ENTRY_CONF}" >> /mnt/gentoo/boot/loader/entries/gentoo.conf
}

user_setting() {
  local -r USER_NAME='virt'

  chroot /mnt/gentoo useradd -m -G wheel -s /bin/bash "${USER_NAME}"
  echo '====================================================='
  echo 'Password of User'
  echo '====================================================='
  chroot /mnt/gentoo passwd "${USER_NAME}"
  echo '====================================================='
  echo 'Password of root'
  echo '====================================================='
  chroot /mnt/gentoo passwd
}

others_configration() {
  local -r NET_INTERFACE=$(ip -br link show | awk 'NR==2 {print $1}')
  local -r WIRED_NETWORK="[Match]
Name=${NET_INTERFACE}

[Network]
DHCP=yes
DNS=8.8.8.8
DNS=8.8.4.4"

  if [[ "${GPU}" == 'nvidia' ]]; then
    local -r ENVIRONMENT="GTK_IM_MODULE='fcitx5'
QT_IM_MODULE='fcitx5'
XMODIFIERS='@im=fcitx5'

LIBVA_DRIVER_NAME='nvidia'
VDPAU_DRIVER='nvidia'"
  elif [[ "${GPU}" == 'amd' ]]; then
    local -r ENVIRONMENT="GTK_IM_MODULE='fcitx5'
QT_IM_MODULE='fcitx5'
XMODIFIERS='@im=fcitx5'

LIBVA_DRIVER_NAME='radeonsi'
VDPAU_DRIVER='radeonsi'"
  fi

  # Network
  echo 'virtualbox' > /mnt/gentoo/etc/hostname
  echo "${WIRED_NETWORK}" >> /mnt/gentoo/etc/systemd/network/20-wired.network
  # env
  echo "${ENVIRONMENT}" >> /mnt/gentoo/etc/environment
  # Time sync
  chroot /mnt/gentoo sed -i -e 's/^#\(NTP=\)/\1ntp.nict.jp/' -e \
    's/^#\(FallbackNTP=\).*/\1ntp1.jst.mfeed.ad.jp ntp2.jst.mfeed.ad.jp ntp3.jst.mfeed.ad.jp/' /etc/systemd/timesyncd.conf

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
