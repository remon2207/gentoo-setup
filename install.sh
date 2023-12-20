#!/usr/bin/env bash

set -eu

usage() {
  cat << EOF
USAGE:
  ${0} <OPTIONS>
OPTIONS:
  -d        Path of disk
  -g        [nvidia, amd]
  -u        Password of user
  -r        Password of root
  -h        See Help
EOF
}

[[ ${#} -eq 0 ]] && usage && exit 1

unalias -a

to-gentoo() { chroot /mnt/gentoo "${@}"; }

BUILD_JOBS="$(("$(nproc)" + 1))" && readonly BUILD_JOBS
LOAD_AVG="$(("${BUILD_JOBS}" * 2)).0" && readonly LOAD_AVG
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)" && readonly SCRIPT_DIR
CPU_INFO="$(grep 'model name' /proc/cpuinfo | awk --field-separator='[ (]' 'NR==1 {print $3}')" && readonly CPU_INFO

while getopts 'd:g:u:r:h' opt; do
  case "${opt}" in
  'd')
    readonly DISK="${OPTARG}"
    ;;
  'g')
    readonly GPU="${OPTARG}"
    ;;
  'u')
    readonly USER_PASSWORD="${OPTARG}"
    ;;
  'r')
    readonly ROOT_PASSWORD="${OPTARG}"
    ;;
  'h')
    usage && exit 0
    ;;
  *)
    usage && exit 1
    ;;
  esac
done

check_variables() {
  case "${GPU}" in
  'nvidia') ;;
  'amd') ;;
  *)
    echo -e '\e[31mgpu typo\e[m' && exit 1
    ;;
  esac
}

partitioning() {
  mkfs.ext4 "${DISK}1"

  mount "${DISK}1" /mnt/gentoo
  mount --mkdir --options='fmask=0077,dmask=0077' /dev/sdd1 /mnt/gentoo/boot
  mount --mkdir "${DISK}2" /mnt/gentoo/home
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
    --expression='s/^\(USE=".*\)pulseaudio /\1/' /etc/portage/make.conf

  if [[ "${GPU}" == 'amd' ]]; then
    to-gentoo sed --in-place \
      --expression='s/^\(VIDEO_CARDS=\).*/\1"amdgpu radeonsi virtualbox"/' \
      --expression='s/^\(USE=".*\)nvenc nvidia /\1/' /etc/portage/make.conf
  fi
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
  to-gentoo emaint --auto sync
  to-gentoo eselect news read
}

profile_package_installation() {
  FEATURES='-ccache' to-gentoo emerge dev-util/ccache
  to-gentoo emerge app-portage/cpuid2cpuflags

  [[ "${GPU}" == 'nvidia' ]] && to-gentoo emerge media-libs/nvidia-vaapi-driver

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

  cp -a "${SCRIPT_DIR}/kernel_conf" /mnt/gentoo/usr/src/linux/.config
  to-gentoo sh -c 'cd /usr/src/linux && make oldconfig && make menuconfig'
  to-gentoo sh -c "cd /usr/src/linux && make --jobs=${BUILD_JOBS} --load-average=${LOAD_AVG} && make modules_install; make install"
  to-gentoo dracut --no-kernel --kver="$(uname --kernel-release | awk --field-separator='-' '{print $1}')-gentoo"

  to-gentoo emerge --update --deep --newuse @world
  to-gentoo emerge --depclean
}

fstab_configration() {
  show_partuuid() { blkid --match-tag='PARTUUID' --output='value' "${1}"; }

  local -r BOOT_PARTUUID="$(show_partuuid /dev/sdd1)"
  local -r ROOT_PARTUUID="$(show_partuuid "${DISK}1")"
  local -r HOME_PARTUUID="$(show_partuuid "${DISK}2")"

  local -r FSTAB="$(
    cat << EOF
PARTUUID=${BOOT_PARTUUID} /boot vfat defaults,noatime                       0 2
PARTUUID=${ROOT_PARTUUID} /     ext4 defaults,noatime                       0 1
PARTUUID=${HOME_PARTUUID} /home ext4 defaults,noatime                       0 2
EOF
  )"

  echo "${FSTAB}" >> /mnt/gentoo/etc/fstab
}

systemd_configration() {
  to-gentoo systemd-machine-id-setup
  to-gentoo systemd-firstboot --keymap='us'
  to-gentoo systemctl preset-all
  to-gentoo bootctl install
}

user_setting() {
  local -r USER_NAME='remon'

  to-gentoo useradd --create-home --groups='wheel' --shell='/bin/bash' "${USER_NAME}"
  echo "${USER_NAME}:${USER_PASSWORD}" | to-gentoo chpasswd
  echo "root:${ROOT_PASSWORD}" | to-gentoo chpasswd
}

others_configration() {
  local -r NET_INTERFACE="$(ip -br link show | awk 'NR==2 {print $1}')"
  local -r WIRED_NETWORK="[Match]
Name=${NET_INTERFACE}

[Network]
DHCP=yes"

  local -r RESOLVED="[Resolve]
DNS=192.168.1.202"

  local -r RESOLVED_FALLBACK="[Resolve]
FallbackDNS=8.8.8.8 8.8.4.4 2001:4860:4860::8888 2001:4860:4860::8844"

  case "${GPU}" in
  'nvidia')
    local -r ENVIRONMENT="GTK_IM_MODULE='fcitx5'
QT_IM_MODULE='fcitx5'
XMODIFIERS='@im=fcitx5'

LIBVA_DRIVER_NAME='nvidia'
VDPAU_DRIVER='nvidia'
NVD_BACKEND='direct'"
    ;;
  'amd')
    local -r ENVIRONMENT="GTK_IM_MODULE='fcitx5'
QT_IM_MODULE='fcitx5'
XMODIFIERS='@im=fcitx5'

LIBVA_DRIVER_NAME='radeonsi'
VDPAU_DRIVER='radeonsi'"
    ;;
  esac

  # Network
  mkdir /mnt/gentoo/etc/systemd/resolved.conf.d

  echo 'gentoo' > /mnt/gentoo/etc/hostname
  echo "${WIRED_NETWORK}" >> /mnt/gentoo/etc/systemd/network/20-wired.network
  echo "${RESOLVED}" > /mnt/gentoo/etc/systemd/resolved.conf.d/dns_servers.conf
  echo "${RESOLVED_FALLBACK}" > /mnt/gentoo/etc/systemd/resolved.conf.d/fallback_dns.conf
  # env
  echo "${ENVIRONMENT}" >> /mnt/gentoo/etc/environment
  # Time sync
  to-gentoo sed --in-place \
    --expression='s/^#\(NTP=\)/\1ntp.nict.jp/' \
    --expression='s/^#\(FallbackNTP=\).*/\1ntp1.jst.mfeed.ad.jp ntp2.jst.mfeed.ad.jp ntp3.jst.mfeed.ad.jp/' /etc/systemd/timesyncd.conf

  to-gentoo emerge app-admin/sudo
  to-gentoo sed --expression='s/^# \(%wheel ALL=(ALL:ALL) ALL\)/\1/' /etc/sudoers | EDITOR='/usr/bin/tee' to-gentoo visudo &> /dev/null

  rm --recursive --force /mnt/gentoo/stage3-*.tar.xz
}

main() {
  check_variables
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
