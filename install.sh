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

readonly TARBALL_DIR='https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-systemd'

STAGE_FILE="$(curl -sL "${TARBALL_DIR}" | grep 'tar.xz"' | awk -F '"' '{print $8}')"
readonly STAGE_FILE

BUILD_JOBS="$(("$(nproc)" + 1))"
readonly BUILD_JOBS

NET_INTERFACE="$(ip -br link show | awk 'NR==2 {print $1}')"
readonly NET_INTERFACE

WIRED_NETWORK="$(
  cat << EOF
[Match]
Name=${NET_INTERFACE}

[Network]
DHCP=yes
DNS=192.168.1.202
EOF
)"
readonly WIRED_NETWORK

SCRIPT_DIR="$(
  cd "$(dirname "${0}")"
  pwd
)"
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

partitioning() {
  mkfs.ext4 "${DISK}1"

  mount "${DISK}1" /mnt/gentoo
  mount -m -o fmask=0077,dmask=0077 /dev/sdd1 /mnt/gentoo/boot
  mount -m "${DISK}2" /mnt/gentoo/home
}

tarball_extract() {
  cd /mnt/gentoo
  wget "${TARBALL_DIR}/${STAGE_FILE}"
  tar xpvf "${STAGE_FILE}" --xattrs-include='*.*' --numeric-owner
}

portage_configration() {
  \cp -a "${SCRIPT_DIR}"/{make.conf,package.{use,license,accept_keywords}} /mnt/gentoo/etc/portage

  mkdir /mnt/gentoo/etc/portage/repos.conf
  cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
  cp -L /etc/resolv.conf /mnt/gentoo/etc/

  chroot /mnt/gentoo sed -i "s/^\(MAKEOPTS=\"-j\).*/\1${BUILD_JOBS}\"/" /etc/portage/make.conf
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
  chroot /mnt/gentoo sed -i 's/^\(CPU_FLAGS_X86=\).*/# \1/' /etc/portage/make.conf
  chroot /mnt/gentoo emerge-webrsync
  chroot /mnt/gentoo emaint sync -a
  chroot /mnt/gentoo eselect news read
}

profile_package_installation() {
  FEATURES='-ccache' chroot /mnt/gentoo emerge dev-util/ccache
  chroot /mnt/gentoo emerge app-portage/cpuid2cpuflags

  [[ "${GPU}" == 'nvidia' ]] && chroot /mnt/gentoo emerge media-libs/nvidia-vaapi-driver

  CPU_FLAGS="$(chroot /mnt/gentoo cpuid2cpuflags | sed 's/^CPU_FLAGS_X86: //g')"
  readonly CPU_FLAGS

  chroot /mnt/gentoo sed -i "s/^# \(CPU_FLAGS_X86=\)/\1\"${CPU_FLAGS}\"/" /etc/portage/make.conf
  chroot /mnt/gentoo emerge -uDN @world
  chroot /mnt/gentoo emerge app-editors/neovim
  chroot /mnt/gentoo emerge --depclean
}

localization() {
  chroot /mnt/gentoo ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
  chroot /mnt/gentoo sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' -e \
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

  cp -a "${SCRIPT_DIR}/gentoo_kernel_conf" /mnt/gentoo/usr/src/linux/.config
  chroot /mnt/gentoo bash -c 'cd /usr/src/linux && make oldconfig'
  chroot /mnt/gentoo bash -c "cd /usr/src/linux && make -j${BUILD_JOBS} && make modules_install && make install"
  chroot /mnt/gentoo dracut --kver "$(uname -r | awk -F '-' '{print $1}')-gentoo" --no-kernel

  chroot /mnt/gentoo emerge -uDN @world
  chroot /mnt/gentoo emerge --depclean
}

fstab_configration() {
  BOOT_PARTUUID="$(blkid -s PARTUUID -o value /dev/sdd1)"
  readonly BOOT_PARTUUID

  ROOT_PARTUUID="$(blkid -s PARTUUID -o value "${DISK}1")"
  readonly ROOT_PARTUUID

  HOME_PARTUUID="$(blkid -s PARTUUID -o value "${DISK}2")"
  readonly HOME_PARTUUID

  FSTAB="$(
    cat << EOF
PARTUUID=${BOOT_PARTUUID} /boot vfat defaults,noatime,fmask=0077,dmask=0077 0 2
PARTUUID=${ROOT_PARTUUID} /     ext4 defaults,noatime                       0 1
PARTUUID=${HOME_PARTUUID} /home ext4 defaults,noatime                       0 2
EOF
  )"
  readonly FSTAB

  #   CACHE_FSTAB=$(
  #     cat << EOF
  # # ramdisk
  # tmpfs /tmp               tmpfs rw,nodev,nosuid,noatime,size=4G,mode=1777                   0 0
  # tmpfs /var/tmp/portage   tmpfs rw,nodev,nosuid,noatime,size=8G                             0 0
  # tmpfs /home/remon/.cache tmpfs rw,nodev,nosuid,noatime,size=8G,mode=0755,uid=1000,gid=1000 0 0
  # EOF
  #   )
  #   readonly CACHE_FSTAB

  echo "${FSTAB}" >> /mnt/gentoo/etc/fstab
}

systemd_configration() {
  chroot /mnt/gentoo systemd-machine-id-setup
  chroot /mnt/gentoo systemd-firstboot --keymap us
  chroot /mnt/gentoo systemctl preset-all
  chroot /mnt/gentoo bootctl install
}

user_setting() {
  readonly USER_NAME='remon'

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

pkgs_installation() {
  chroot /mnt/gentoo emerge app-eselect/eselect-repository dev-vcs/git
  chroot /mnt/gentoo eselect repository enable guru gentoo-zh
  for repos in guru gentoo-zh; do chroot /mnt/gentoo emaint sync -r "${repos}"; done
  chroot /mnt/gentoo sed -i 's/pulseaudio //' /etc/portage/make.conf
  chroot /mnt/gentoo emerge media-video/{wireplumber,pipewire} \
    media-sound/{pulseaudio,pavucontrol} \
    media-libs/{libpulse,nvidia-vaapi-driver} \
    app-admin/sudo \
    app-containers/docker{,-cli} \
    app-emulation/virtualbox{,-additions,-guest-additions,-extpack-oracle} \
    app-i18n/{fcitx{,-configtool,-gtk,-qt}:5,mozc} \
    app-misc/{ghq,jq,neofetch,ranger,tmux} \
    app-shells/{fzf,gentoo-zsh-completions,starship,zsh} \
    app-text/tldr \
    dev-lang/go \
    dev-util/{git-delta,github-cli,shellcheck} \
    dev-vcs/lazygit \
    media-fonts/{fontawesome,hack,nerd-fonts,noto{,-cjk,-emoji}} \
    media-gfx/{feh,scrot,silicon} \
    net-im/{discord,slack} \
    net-fs/nfs-utils \
    sys-apps/{bat,fd,lsd,pciutils,ripgrep,sd} \
    sys-process/htop \
    www-client/{vivaldi,w3m} \
    www-misc/profile-sync-daemon \
    x11-base/xorg-server \
    x11-misc/{dunst,i3lock,picom,polybar,qt5ct,rofi,xautolock,xdg-user-dirs} \
    x11-terms/{alacritty,kitty,wezterm} \
    x11-themes/{arc-theme,breezex-xcursors,kvantum,papirus-icon-theme} \
    x11-wm/i3
  chroot /mnt/gentoo sed -i 's/^USE="/&pulseaudio /' /etc/portage/make.conf
  chroot /mnt/gentoo emerge -uDN @world
}

group_configration() {
  for groups in video pipewire; do chroot /mnt/gentoo gpasswd -a "${USER_NAME}" "${groups}"; done
}

others_configration() {
  # Network
  echo 'gentoo' > /mnt/gentoo/etc/hostname
  echo "${WIRED_NETWORK}" >> /mnt/gentoo/etc/systemd/network/20-wired.network
  # env
  echo "${ENVIRONMENT}" >> /mnt/gentoo/etc/environment
  # Time sync
  chroot /mnt/gentoo sed -i 's/^#\(NTP=\)/\1ntp.nict.jp/' -e \
    's/^#\(FallbackNTP=\).*/\1ntp1.jst.mfeed.ad.jp ntp2.jst.mfeed.ad.jp ntp3.jst.mfeed.ad.jp/' /etc/systemd/timesyncd.conf

  rm /mnt/gentoo/stage3-*.tar.xz
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
  pkgs_installation
  group_configration
  others_configration
}

main "${@}"
