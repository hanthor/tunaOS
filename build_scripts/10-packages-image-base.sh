#!/usr/bin/env bash

set -xeuo pipefail
MAJOR_VERSION_NUMBER="$(sh -c '. /usr/lib/os-release ; echo ${VERSION_ID%.*}')"

# This is the base for a minimal GNOME system on CentOS Stream.

# This thing slows down downloads A LOT for no reason
# dnf remove -y subscription-manager

# dnf -y install centos-release-hyperscale-kernel
# dnf config-manager --set-disabled "centos-hyperscale,centos-hyperscale-kernel"
# dnf --enablerepo="centos-hyperscale" --enablerepo="centos-hyperscale-kernel" -y update kernel

# The base images take super long to update, this just updates manually for now
dnf -y install 'dnf-command(versionlock)'
dnf versionlock add kernel kernel-devel kernel-devel-matched kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-uki-virt

dnf -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${MAJOR_VERSION_NUMBER}.noarch.rpm"
/usr/bin/crb enable

dnf swap -y coreutils-single coreutils

# Multimidia codecs
# dnf config-manager --add-repo=https://negativo17.org/repos/epel-multimedia.repo
# dnf config-manager --set-disabled epel-multimedia
dnf -y install \
	ffmpeg-free @multimedia gstreamer1-plugins-{bad-free,bad-free-libs,good,base} lame{,-libs}

dnf group install -y --nobest \
	"Server with GUI" \

# Minimal GNOME group. ("Multimedia" adds most of the packages from the GNOME group. This should clear those up too.)
# In order to reproduce this, get the packages with `dnf group info GNOME`, install them manually with dnf install and see all the packages that are already installed.
# Other than that, I've removed a few packages we didnt want, those being a few GUI applications.
dnf -y install \
	-x PackageKit \
	"NetworkManager-adsl" \
	"almalinux-backgrounds" \
	"buildah" \
	"cockpit" \
	"cockpit-files" \
	"cockpit-image-builder" \
	"cockpit-machines" \
	"cockpit-podman" \
	"cockpit-ws" \
	"distrobox" \
	"fastfetch" \
	"fpaste" \
	"fzf" \
	"git" \
	"gdm" \
	"glow" \
	"gnome-bluetooth" \
	"gnome-color-manager" \
	"gnome-control-center" \
	"gnome-disk-utility" \
	"gnome-extensions-app" \
	"gnome-remote-desktop" \
	"gnome-session-wayland-session" \
	"gnome-settings-daemon" \
	"gnome-shell" \
	"gnome-shell-extension-appindicator" \
	"gnome-shell-extension-blur-my-shell" \
	"gnome-shell-extension-dash-to-dock" \
	"gnome-software" \
	"gnome-software-fedora-langpacks" \
	"gnome-user-docs" \
	"gvfs-fuse" \
	"gvfs-goa" \
	"gvfs-gphoto2" \
	"gvfs-mtp" \
	"gvfs-smb" \
	"gum" \
	"jetbrains-mono-fonts-all" \
	"just" \
	"libcamera-gstreamer" \
	"libcamera-tools" \
	"libcamera-v4l2" \
	"libsane-hpaio" \
	"libvirt" \
	"powertop" \
	"tuned-ppd" \
	"fzf" \
	"glow" \
	"wl-clipboard" \
	"gum" \
	"nautilus" \
	"orca" \
	"plymouth" \
	"plymouth-system-theme" \
	"ptyxis" \
	"qemu-kvm" \
	"sane-backends-drivers-scanners" \
	"system-reinstall-bootc" \
	"systemd-container" \
	"systemd-oomd" \
	"systemd-resolved" \
	"wl-clipboard" \
	"xdg-desktop-portal-gnome" \
	"xdg-user-dirs-gtk" \
	"xhost" \
	"yelp-tools"

# This package adds "[systemd] Failed Units: *" to the bashrc startup
dnf -y remove console-login-helper-messages
