#!/usr/bin/env bash

set -eu

pkgs_installation() {
  sudo emerge app-eselect/eselect-repository dev-vcs/git
  sudo eselect repository enable guru gentoo-zh

  for repos in guru gentoo-zh; do emaint sync -r "${repos}"; done

  sudo emerge media-video/{wireplumber,pipewire} \
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

  sudo sed -i -e 's/^USE="/&pulseaudio /' /etc/portage/make.conf
  sudo emerge -uDN @world
}

group_configration() {
  for groups in video pipewire vboxguest vboxusers; do sudo gpasswd -a "${USER}" "${groups}"; done

  sudo systemctl enable --now {virtualbox-guest-additions,docker}.service
  systemctl --user disable --now pulseaudio.{socket,service}
  systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service
}

fstab_configration() {
  CACHE_FSTAB=$(
    cat << EOF
# ramdisk
tmpfs /tmp               tmpfs rw,nodev,nosuid,noatime,size=4G,mode=1777                   0 0
tmpfs /var/tmp/portage   tmpfs rw,nodev,nosuid,noatime,size=8G                             0 0
tmpfs /home/remon/.cache tmpfs rw,nodev,nosuid,noatime,size=8G,mode=0755,uid=1000,gid=1000 0 0
EOF
  )
  readonly CACHE_FSTAB

  echo "${CACHE_FSTAB}" >> /mnt/gentoo/etc/fstab
}

main() {
  pkgs_installation
  group_configration
  fstab_configration
}

main "${@}"