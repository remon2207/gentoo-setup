```bash
BUILD_JOBS="$(("$(nproc)" + 1))" && readonly BUILD_JOBS
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)" && readonly SCRIPT_DIR
CPU_INFO="$(grep 'model name' /proc/cpuinfo | awk -F '[ (]' 'NR==1 {print $3}')" && readonly CPU_INFO

gdisk /dev/sda

mount /dev/sda2 /mnt/gentoo
mount -m -o fmask=0077,dmask=0077 /dev/sda1 /mnt/gentoo/boot
mount -m /dev/sda3 /mnt/gentoo/home

cd /mnt/gentoo
links https://www.gentoo.org/downloads/mirrors/
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

vim /etc/portage/make.conf
# COMMON_FLAGS="-march=skylake -O2 -pipe"
# MAKEOPTS="-j<nproc+1> -l<nproc+1>"
# LINGUAS="ja en"
# L10N="ja en"
# VIDEO_CARDS="nvidia virtualbox"
# VIDEO_CARDS="amdgpu radeonsi virtualbox"
# INPUT_DEVICES="libinput"
# USE="nvenc opengl policykit vdpau vulkan nvidia vaapi pulseaudio cjk systemd X gtk -upnp -upnp-av -semantic-desktop -rss -rdp -ppds -pcmcia -mms -hddtemp -handbook -gphoto2 -gimp -dedicated -clamav -coreaudio -apache2 -aqua -bash-completion -gdbm -qdbm -mssql -mysql -mysqli -oci8 -oci8-instant-client -oracle -postgres -cdb -dbi -dbm -firebird -freetds -odbc -sqlite -smartcard -scanner -joystick -maildir -mbox -milter -networkmanager -screencast -wifi -xscreensaver -alsa -elogind -syslog -qt5 -qt6 -gnome -kde -plasma -wayland"
# USE="opengl policykit vdpau vaapi vulkan cjk systemd X gtk -upnp -upnp-av -semantic-desktop -rss -rdp -ppds -pcmcia -mms -hddtemp -handbook -gphoto2 -gimp -dedicated -clamav -coreaudio -apache2 -aqua -bash-completion -gdbm -qdbm -mssql -mysql -mysqli -oci8 -oci8-instant-client -oracle -postgres -cdb -dbi -dbm -firebird -freetds -odbc -sqlite -smartcard -scanner -joystick -maildir -mbox -milter -networkmanager -screencast -wifi -xscreensaver -alsa -elogind -syslog -qt5 -qt6 -gnome -kde -plasma -wayland"

mirrorselect -i -o >> /mnt/gentoo/etc/portage/make.conf

mkdir /mnt/gentoo/etc/portage/repos.conf
cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
cp --dereference /etc/resolv.conf /mnt/gentoo/etc

mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

chroot /mnt/gentoo /bin/bash
source /etc/profile
export PS1="(chroot) ${PS1}"


# CPUがIntel
echo 'sys-firmware/intel-microcode intel-ucode' > /etc/portage/package.license/intel-microcode
echo 'sys-firmware/intel-microcode initramfs' > /etc/portage/package.use/intel-microcode
# CPUがAMD
echo 'sys-kernel/linux-firmware initramfs' > /etc/portage/package.use/linux-firmware

echo 'sys-kernel/linux-firmware @BINARY-REDISTRIBUTABLE' > /etc/portage/package.license/linux-firmware
echo 'sys-apps/systemd boot kernel-install' > /etc/portage/package.use/systemd

emerge-webrsync
emaint sync -a
eselect news list
eselect news read
eselect profile list
eselect profile set

emerge app-portage/cpuid2cpuflags
cpuid2cpuflags | sed -e 's/^CPU_FLAGS_X86: \(.*\)/CPU_FLAGS_X86="\1"/' >> make.conf
vim /etc/portage/make.conf

emerge -avuDN @world
emerge -av app-editors/neovim
emerge -a --depclean

ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime

vim /etc/locale.gen
# '#en_US.UTF-8 UTF-8' to 'en_US.UTF-8 UTF-8'
# '#ja_JP.UTF-8 UTF-8' to 'ja_JP.UTF-8 UTF-8'
locale-gen
eselect locale set 4

env-update && source /etc/profile && export PS1="(chroot) ${PS1}"

# CPUがIntel
emerge -av sys-firmware/intel-microcode

emerge -av sys-kernel/{linux-firmware,gentoo-sources,dracut}
eselect kernel set 1

# lspci
emerge -a sys-apps/pciutils

cd /usr/src/linux
make menuconfig
make -j<nroc+1> && make modules_install
make install

dracut --kver <kernel-version>-gentoo

emerge -avuDN @world
emerge emerge -a --depclean

vim /etc/fstab
# PARTUUID=</dev/sda1> /boot vfat defaults,noatime,fmask=0077,dmask=0077 0 2
# PARTUUID=</dev/sda2> /     ext4 defaults,noatime                       0 1
# PARTUUID=</dev/sda3> /home ext4 defaults,noatime                       0 2

echo 'gentoo' > /etc/hostname

vim /etc/systemd/network/20-wired.network
# [Match]
# Name=<network-interface>
#
# [Network]
# If DHCP
# DHCP=

# If static ip
# Address=
# Gateway=

# DNS=

passwd

systemd-machine-id-setup
systemd-firstboot --prompt
systemctl preset-all

vim /etc/systemd/timesyncd.conf

bootctl install
vim /boot/loader/loader.conf
# timeout      15
# console-mode max
# editor       no
vim /boot/loader/entries/gentoo.conf
# title      Gentoo
# linux      /<vmlinuz>
# initrd     /<ucode>
# initrd     /<initramfs>
# machine-id </etc/machine-id>
# options    root=PARTUUID=</dev/sda2> rw loglevel=3 panic=180

rm /stage3-*.tar.xz

exit
umount -R /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo
reboot

useradd -m -G wheel -s /bin/bash remon
passwd remon

echo 'app-admin/sudo -sendmail' > /etc/portage/package.use/sudo
emerge -av app-admin/sudo
EDITOR=nvim visudo
# '# %wheel ALL=(ALL:ALL) ALL' to '%wheel ALL=(ALL:ALL) ALL'

exit

sudo nvim /etc/environment
# GTK_IM_MODULE='fcitx5'
# QT_IM_MODULE='fcitx5'
# XMODIFIERS='@im=fcitx5'

# if NVIDIA
# LIBVA_DRIVER_NAME='nvidia'
# VDPAU_DRIVER='nvidia'"

# if AMD
# LIBVA_DRIVER_NAME='radeonsi'
# VDPAU_DRIVER='radeonsi'"

sudo emerge -avuDN @world
sudo emerge -a --depclean

sudo emerge -av app-eselect/eselect-repository dev-vcs/git
sudo eselect repository enable guru gentoo-zh
sudo eselect repository add remon-overlay git https://github.com/remon2207/remon-overlay.git

sudo emaint sync -r guru
sudo emaint sync -r gentoo-zh
sudo emaint sync -r remon-overlay

# Sound
sudo emerge -av media-video/{wireplumber,pipewire} media-sound/{pulseaudio,pavucontrol} media-libs/libpulse

# xorg
sudo emerge -av x11-base/xorg-server
# If NVIDIA
sudo emerge -av media-libs/nvidia-vaapi-driver

sudo emerge -av \
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
  sys-apps/{bat,fd,lsd,ripgrep,sd} \
  sys-auth/authy \
  sys-process/htop \
  www-client/{vivaldi,w3m} \
  www-misc/profile-sync-daemon \
  x11-misc/{dunst,i3lock,picom,polybar,qt5ct,rofi,xautolock,xdg-user-dirs} \
  x11-terms/{alacritty,kitty,wezterm} \
  x11-themes/{arc-theme,breezex-xcursors,kvantum,papirus-icon-theme} \
  x11-wm/i3

sudo nvim /etc/portage/make.conf
# USE="pulseaudio"

sudo emerge -avuDN @world
sudo emerge -a --depclean

emerge -av dev-util/ccache
sudo nvim /etc/portage/make.conf
# FEATURES="ccache"
# CCACHE_SIZE="2G"

sudo emerge -avuDN @world
sudo emerge -a --depclean
```

