#!/usr/bin/env bash

set -u

pkgs_installation() {
  sudo emerge app-eselect/eselect-repository dev-vcs/git
  sudo eselect repository enable guru gentoo-zh
  sudo eselect repository add remon-overlay git https://github.com/remon2207/remon-overlay.git

  for repos in guru gentoo-zh remon-overlay; do sudo emaint sync --repo "${repos}"; done

  sudo emerge media-video/{wireplumber,pipewire} \
    media-sound/{pulseaudio,pavucontrol} \
    app-containers/docker{,-cli,-compose} \
    app-emulation/virtualbox{,-additions,-guest-additions,-extpack-oracle} \
    app-i18n/{fcitx{,-configtool,-gtk,-qt}:5,mozc} \
    app-misc/{ghq,jq,neofetch,ranger,tmux} \
    app-shells/{fzf,gentoo-zsh-completions,starship,zsh} \
    app-text/{tldr,highlight,tree} \
    dev-util/{git-delta,github-cli,shellcheck,stylua,yamlfmt,shfmt} \
    dev-vcs/{lazygit,rcs} \
    media-fonts/{fontawesome,hack,nerd-fonts,noto{,-cjk,-emoji}} \
    media-gfx/{feh,scrot,silicon} \
    net-fs/nfs-utils \
    net-im/{discord,slack} \
    net-misc/httpie \
    sys-apps/{bat,fd,lsd,pciutils,ripgrep,sd} \
    sys-auth/authy \
    sys-fs/duf \
    sys-process/{htop,procs} \
    www-client/{vivaldi,w3m} \
    www-misc/profile-sync-daemon \
    x11-apps/{xrandr,xev} \
    x11-base/xorg-server \
    x11-misc/{dunst,picom,polybar,qt5ct,rofi,xautolock,xdg-user-dirs} \
    x11-terms/{alacritty,kitty,wezterm} \
    x11-themes/{arc-theme,breezex-xcursors,kvantum,papirus-icon-theme} \
    x11-wm/i3

  sudo sed --in-place --expression='s/^USE="/&pulseaudio /' /etc/portage/make.conf
  sudo emerge --update --deep --newuse @world
  sudo emerge --depclean

  sudo cp --archive /etc/dispatch-conf.conf{,.org}
  sudo sed --in-place \
    --expression='s/^\(use-rcs=\).*$/\1yes/' \
    --expression="s/^\(diff=\"\).*\(\"\)$/\1delta --syntax-theme='Solarized (dark)' --line-numbers '%s' '%s'\2/" \
    --expression="s/^\(pager=\"\).*\(\"\)$/\1bat --plain\2/" /etc/dispatch-conf.conf
}

group_configration() {
  for groups in video pipewire vboxguest vboxusers; do sudo gpasswd --add "${USER}" "${groups}"; done

  sudo systemctl enable {virtualbox-guest-additions,docker}.service
  systemctl --user disable pulseaudio.{socket,service}
  systemctl --user enable pipewire.socket pipewire-pulse.socket wireplumber.service
}

fstab_configration() {
  local -r CACHE_FSTAB="$(
    cat << EOF
# ramdisk
tmpfs /tmp               tmpfs rw,async,nodev,nosuid,noatime,size=1G,mode=1777                                   0 0
tmpfs /var/tmp/portage   tmpfs rw,async,nodev,nosuid,noatime,size=8G                                             0 0
tmpfs ${HOME}/.cache tmpfs rw,async,nodev,nosuid,noatime,nomand,lazytime,size=1G,mode=0755,uid=1000,gid=1000 0 0
tmpfs ${HOME}/tmp    tmpfs rw,async,nodev,nosuid,noatime,nomand,lazytime,size=1G,mode=0755,uid=1000,gid=1000 0 0
EOF
  )"

  echo "${CACHE_FSTAB}" | sudo tee --append /etc/fstab &> /dev/null
}

other() {
  ln --symbolic --force /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  cp --archive /etc/X11/xinit/xinitrc "${HOME}/.xinitrc"
  rm ----recursive --force /tmp /var/tmp/portage "${HOME}/.cache"
}

main() {
  pkgs_installation
  group_configration
  fstab_configration
  other
}

sudo systemctl set-ntp true
main "${@}"
