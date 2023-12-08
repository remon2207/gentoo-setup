#!/usr/bin/env bash

set -eu

unalias -a

readonly DISK='/dev/sda'
BUILD_JOBS="$(("$(nproc)" + 1))" && readonly BUILD_JOBS
LOAD_AVG="$(("${BUILD_JOBS}" * 2))" && readonly LOAD_AVG
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)" && readonly SCRIPT_DIR
CPU_INFO="$(grep 'model name' /proc/cpuinfo | awk --field-separator='[ (]' 'NR==1 {print $3}')" && readonly CPU_INFO

to-gentoo() { chroot /mnt/gentoo "${@}"; }

partitioning() {
  local -r EFI_PART_TYPE="$(sgdisk --list-types | grep 'ef00' | awk '{print $6,$7,$8}')"
  local -r NORMAL_PART_TYPE="$(sgdisk --list-types | grep '8300' | awk '{print $2,$3}')"

  sgdisk --zap-all "${DISK}"
  sgdisk --new='0::+512M' --typecode='0:ef00' --change-name="0:${EFI_PART_TYPE}" "${DISK}"
  sgdisk --new='0::' --typecode='0:8300' --change-name="0:${NORMAL_PART_TYPE}" "${DISK}"

  mkfs.vfat -F 32 "${DISK}1"
  mkfs.ext4 "${DISK}2"

  mount "${DISK}2" /mnt/gentoo
  mount --mkdir --options='fmask=0077,dmask=0077' "${DISK}1" /mnt/gentoo/boot
}

tarball_extract() {
  local -r TARBALL_DIR='https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-systemd'
  local -r STAGE_FILE="$(curl --fail --silent --show-error --location "${TARBALL_DIR}" | grep 'tar.xz"' | awk --field-separator='"' '{print $8}')"

  cd /mnt/gentoo
  curl --fail --silent --show-error --remote-name --location "${TARBALL_DIR}/${STAGE_FILE}"
  tar --extract --same-permissions --verbose --file="${STAGE_FILE}" --xattrs-include='*.*' --numeric-owner
}

portage_configration() {
  cp --archive "${SCRIPT_DIR}/"{make.conf,package.{mask,use,license,accept_keywords}} /mnt/gentoo/etc/portage

  mkdir /mnt/gentoo/etc/portage/repos.conf
  cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
  cp --dereference /etc/resolv.conf /mnt/gentoo/etc

  case "${CPU_INFO}" in
  'Intel')
    echo 'sys-firmware/intel-microcode initramfs' > /mnt/gentoo/etc/portage/package.use/intel-microcode
    rm --recursive --force /mnt/gentoo/etc/portage/package.use/linux-firmware
    ;;
  'AMD')
    echo 'sys-kernel/linux-firmware initramfs' > /mnt/gentoo/etc/portage/package.use/linux-firmware
    rm --recursive --force /mnt/gentoo/etc/portage/package.use/intel-microcode
    ;;
  esac

  to-gentoo sed --in-place \
    --expression="s/^\(MAKEOPTS=\"\).*/\1--jobs=${BUILD_JOBS} --load-average=${LOAD_AVG}\"/" \
    --expression="s/^\(EMERGE_DEFAULT_OPTS=\"\).*/\1--jobs=${BUILD_JOBS} --load-average=${LOAD_AVG} --tree --verbose\"/" \
    --expression='s/^\(CPU_FLAGS_X86=\).*/# \1/' \
    --expression='s/^\(VIDEO_CARDS=\).*/\1"virtualbox"/' \
    --expression='s/^\(USE=".*\)pulseaudio /\1/' \
    --expression='s/^\(USE=".*\)nvenc nvidia /\1/' /etc/portage/make.conf
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
  to-gentoo emerge-webrsync
  to-gentoo emaint sync --auto
  to-gentoo eselect news read
}

profile_package_installation() {
  FEATURES='-ccache' to-gentoo emerge dev-util/ccache
  to-gentoo emerge app-portage/cpuid2cpuflags

  local -r CPU_FLAGS="$(to-gentoo cpuid2cpuflags | cut --delimiter=' ' --fields='2-')"

  to-gentoo sed --in-place --expression="s/^# \(CPU_FLAGS_X86=\)/\1\"${CPU_FLAGS}\"/" /etc/portage/make.conf
  to-gentoo emerge --update --deep --newuse @world
  to-gentoo emerge app-editors/neovim
  to-gentoo emerge --depclean
}

localization() {
  to-gentoo ln --symbolic --force /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
  to-gentoo sed --in-place \
    --expression='s/^#\(en_US.UTF-8 UTF-8\)/\1/' \
    --expression='s/^#\(ja_JP.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  to-gentoo locale-gen
  to-gentoo eselect locale set 4

  to-gentoo env-update
  # shellcheck disable=SC1091
  . /mnt/gentoo/etc/profile
}

kernel_installation() {
  to-gentoo emerge sys-kernel/{linux-firmware,gentoo-sources,dracut}

  [[ "${CPU_INFO}" == 'Intel' ]] && to-gentoo emerge sys-firmware/intel-microcode

  to-gentoo eselect kernel set 1

  cp --archive "${SCRIPT_DIR}/kernel_conf" /mnt/gentoo/usr/src/linux/.config
  to-gentoo bash -c 'cd /usr/src/linux && make oldconfig && make menuconfig'
  to-gentoo bash -c "cd /usr/src/linux && make --jobs=${BUILD_JOBS} --load-average=${LOAD_AVG} && make modules_install; make install"
  to-gentoo dracut --no-kernel --kver="$(uname --kernel-release | awk --field-separator='-' '{print $1}')-gentoo"

  to-gentoo emerge --update --deep --newuse @world
  to-gentoo emerge --depclean
}

fstab_configration() {
  show_partuuid() { blkid --match-tag='PARTUUID' --output='value' "${1}"; }

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
  to-gentoo systemd-machine-id-setup
  to-gentoo systemd-firstboot --keymap='us'
  to-gentoo systemctl preset-all
  to-gentoo bootctl install

  find_boot() { find /mnt/gentoo/boot -type 'f' -name "${1}"; }

  local -r MACHINE_ID="$(cat /mnt/gentoo/etc/machine-id)"
  local -r VMLINUZ="$(find_boot '*vmlinuz*gentoo' | awk --field-separator='/' '{print $5}')"
  local -r UCODE="$(find_boot '*uc*' | awk --field-separator='/' '{print $5}')"
  local -r INITRAMFS="$(find_boot '*initramfs*gentoo*' | awk --field-separator='/' '{print $5}')"

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

  to-gentoo useradd --create-home --groups='wheel' --shell='/bin/bash' "${USER_NAME}"
  echo "${USER_NAME}:virt" | to-gentoo chpasswd
  echo 'root:root' | to-gentoo chpasswd
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
  to-gentoo sed --in-place \
    --expression='s/^#\(NTP=\)/\1ntp.nict.jp/' \
    --expression='s/^#\(FallbackNTP=\).*/\1ntp1.jst.mfeed.ad.jp ntp2.jst.mfeed.ad.jp ntp3.jst.mfeed.ad.jp/' /etc/systemd/timesyncd.conf

  to-gentoo emerge app-admin/sudo
  to-gentoo sed --expression='s/^# \(%wheel ALL=(ALL:ALL) ALL\)/\1/' /etc/sudoers | EDITOR='/usr/bin/tee' to-gentoo visudo &> /dev/null

  rm --recursive --force /mnt/gentoo/stage3-*.tar.xz
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
