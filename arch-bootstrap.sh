#!/bin/bash
#
# arch-bootstrap: Bootstrap a base Arch Linux system using any GNU distribution.
#
# Dependencies: bash >= 4, coreutils, curl, sed, gawk, tar, gzip, chroot, xz, zstd.
# Project: https://github.com/tokland/arch-bootstrap
#
# Install:
#
#   # install -m 755 arch-bootstrap.sh /usr/local/bin/arch-bootstrap
#
# Usage:
#
#   # arch-bootstrap destination
#   # arch-bootstrap -r https://geo.mirror.pkgbuild.com destination
#
# And then you can chroot to the destination directory (user: root, password: root):
#
#   # chroot destination

set -e -u -o pipefail

# Packages needed by pacman (see get-pacman-dependencies.sh)
PACMAN_PACKAGES=(
  acl archlinux-keyring attr brotli bzip2 curl expat glibc gpgme libarchive
  libassuan libgpg-error libnghttp2 libnghttp3 libngtcp2 libssh2 lzo openssl pacman pacman-mirrorlist xz zlib
  krb5 e2fsprogs keyutils libidn2 libunistring libgcc libstdc++ lz4 libpsl icu libseccomp zstd libxml2
)
BASIC_PACKAGES=(${PACMAN_PACKAGES[*]} filesystem base)
EXTRA_PACKAGES=(coreutils bash grep gawk file tar gzip systemd sed)
DEFAULT_REPO_URL="https://geo.mirror.pkgbuild.com"
ARCH="x86_64"

stderr() { 
  echo "$@" >&2 
}

debug() {
  stderr "--- $@"
}

extract_href() {
  sed -n '/<a / s/^.*<a [^>]*href="\([^\"]*\)".*$/\1/p'
}

fetch() {
  curl -L -s "$@"
}

fetch_file() {
  local FILEPATH=$1
  shift
  if [[ -e "$FILEPATH" ]]; then
    curl -L -z "$FILEPATH" -o "$FILEPATH" "$@"
  else
    curl -L -o "$FILEPATH" "$@"
  fi
}

uncompress() {
  local FILEPATH=$1 DEST=$2
  
  case "$FILEPATH" in
    *.gz) 
      tar xzf "$FILEPATH" -C "$DEST";;
    *.xz) 
      xz -dc "$FILEPATH" | tar x -C "$DEST";;
    *.zst)
      zstd -dc "$FILEPATH" | tar x -C "$DEST";;
    *)
      debug "Error: unknown package format: $FILEPATH"
      return 1;;
  esac
}  

###

get_core_repo_url() {
  local REPO_URL=$1 ARCH=$2
  echo "${REPO_URL%/}/core/os/$ARCH"
}

get_template_repo_url() {
  local REPO_URL=$1 ARCH=$2
  echo "${REPO_URL%/}/\$repo/os/$ARCH"
}

configure_pacman() {
  local DEST=$1 ARCH=$2
  debug "configure DNS and pacman"
  cp "/etc/resolv.conf" "$DEST/etc/resolv.conf"
  SERVER=$(get_template_repo_url "$REPO_URL" "$ARCH")
  echo "Server = $SERVER" > "$DEST/etc/pacman.d/mirrorlist"
}

configure_minimal_system() {
  local DEST=$1
  
  mkdir -p "$DEST/dev"
  sed -ie 's/^root:.*$/root:$1$GT9AUpJe$oXANVIjIzcnmOpY07iaGi\/:14657::::::/' "$DEST/etc/shadow"
  touch "$DEST/etc/group"
  echo "bootstrap" > "$DEST/etc/hostname"

  rm -f "$DEST/etc/mtab"
  echo "rootfs / rootfs rw 0 0" > "$DEST/etc/mtab"
  test -e "$DEST/dev/null" || mknod "$DEST/dev/null" c 1 3
  test -e "$DEST/dev/random" || mknod -m 0644 "$DEST/dev/random" c 1 8
  test -e "$DEST/dev/urandom" || mknod -m 0644 "$DEST/dev/urandom" c 1 9

  sed -i 's|^#XferCommand = /usr/bin/curl -L|XferCommand = /usr/bin/curl -k -L|' "$DEST/etc/pacman.conf"
  sed -i 's/^DownloadUser/#DownloadUser/' "$DEST/etc/pacman.conf"
  sed -i "s/^[[:space:]]*\(CheckSpace\)/# \1/" "$DEST/etc/pacman.conf"
  sed -i "s/^[[:space:]]*SigLevel[[:space:]]*=.*$/SigLevel = Never/" "$DEST/etc/pacman.conf"
}

fetch_packages_list() {
  local REPO=$1 
  
  debug "fetch packages list: $REPO/"
  fetch "$REPO/" | extract_href | awk -F"/" '{print $NF}' | sort -rn ||
    { debug "Error: cannot fetch packages list: $REPO"; return 1; }
}

install_pacman_packages() {
  local BASIC_PACKAGES=$1 DEST=$2 LIST=$3 DOWNLOAD_DIR=$4
  debug "pacman package and dependencies: $BASIC_PACKAGES"
  
  for PACKAGE in $BASIC_PACKAGES; do
    local ESC_PACKAGE=$(echo "$PACKAGE" | sed 's/+/%2B/g')
    local FILE=$(echo "$LIST" | grep -m1 "^$ESC_PACKAGE-[[:digit:]].*\(\.gz\|\.xz\|\.zst\)$")
    test "$FILE" || { debug "Error: cannot find package: $PACKAGE"; return 1; }
    local FILEPATH="$DOWNLOAD_DIR/$FILE"
    
    debug "download package: $REPO/$FILE"
    fetch_file "$FILEPATH" "$REPO/$FILE"
    debug "uncompress package: $FILEPATH"
    uncompress "$FILEPATH" "$DEST"
  done
}

mount_pseudo() {
  local DEST=$1
  LC_ALL=C mount --types proc /proc "$DEST/proc"
  LC_ALL=C mount --rbind /sys "$DEST/sys"
  LC_ALL=C mount --make-rslave "$DEST/sys"
  LC_ALL=C mount --rbind /dev "$DEST/dev"
  LC_ALL=C mount --make-rslave "$DEST/dev"
}

unmount_all() {
  local DEST=$1
  for m in proc sys dev; do
    ! mountpoint -q "$DEST/$m" || LC_ALL=C umount -R "$DEST/$m"
  done
}

# Enter the rootfs without depending on arch-install-scripts (arch-chroot).
# The host may be any GNU distro, so we reuse our own mount logic.
enter_chroot() {
  local DEST=$1; shift
  trap "unmount_all '$DEST'" EXIT KILL TERM
  mount_pseudo "$DEST"
  [[ -e /etc/resolv.conf ]] && cp "/etc/resolv.conf" "$DEST/etc/resolv.conf"
  LC_ALL=C chroot "$DEST" "$@" || true
  unmount_all "$DEST"
}

# Replace the bootstrap-temp pacman.conf (SigLevel=Never, curl -k, no DownloadUser)
# with the official one so the finished system is configured normally and securely.
# Source is offline: the .pacnew pacman may have written, else the pristine conf
# shipped inside the cached pacman package.
restore_pacman_conf() {
  local DEST=$1 DOWNLOAD_DIR=$2 CONF="$DEST/etc/pacman.conf"
  if [[ -e "$CONF.pacnew" ]]; then
    debug "restore official pacman.conf (from .pacnew)"
    mv "$CONF.pacnew" "$CONF"
    return 0
  fi
  local PKG=$(echo "$DOWNLOAD_DIR"/pacman-[0-9]*.pkg.tar.*)
  [[ -e "$PKG" ]] || { debug "warning: pacman package not found, keeping temp pacman.conf"; return 0; }
  debug "restore official pacman.conf (from $PKG)"
  tar --zstd -xf "$PKG" -C "$DEST" etc/pacman.conf
}

install_packages() {
  local ARCH=$1 DEST=$2 PACKAGES=$3
  debug "install packages: $PACKAGES"
  mount_pseudo "$DEST"
  LC_ALL=C chroot "$DEST" /usr/bin/pacman \
    --noconfirm --disable-sandbox --arch $ARCH -Sy --overwrite \* $PACKAGES
  unmount_all "$DEST"
}

# Initialize and populate the pacman keyring from the shipped archlinux-keyring,
# so the finished system trusts package signatures out of the box (no chicken-egg
# where verifying archlinux-keyring would itself need a populated keyring).
init_keyring() {
  local DEST=$1
  debug "initialize pacman keyring"
  mount_pseudo "$DEST"
  LC_ALL=C chroot "$DEST" /usr/bin/pacman-key --init
  LC_ALL=C chroot "$DEST" /usr/bin/pacman-key --populate archlinux
  unmount_all "$DEST"
}

show_usage() {
  stderr "Usage: $(basename "$0") [-c] [-r REPO_URL] [-d DOWNLOAD_DIR] DESTDIR"
  stderr "       -c   chroot into an already-bootstrapped DESTDIR (no arch-install-scripts needed)"
}

main() {
  # Process arguments and options
  test $# -eq 0 && set -- "-h"
  local REPO_URL=
  local CHROOT_ONLY=
  local DOWNLOAD_DIR=
  local PRESERVE_DOWNLOAD_DIR=

  while getopts "cr:d:h" ARG; do
    case "$ARG" in
      r) REPO_URL=$OPTARG;;
      c) CHROOT_ONLY=true;;
      d) DOWNLOAD_DIR=$OPTARG
         PRESERVE_DOWNLOAD_DIR=true;;
      *) show_usage; return 1;;
    esac
  done
  shift $(($OPTIND-1))
  test $# -eq 1 || { show_usage; return 1; }

  [[ -z "$REPO_URL" ]] && REPO_URL=$DEFAULT_REPO_URL

  local DEST=$1

  # Chroot-only mode: reuse our mount logic instead of arch-chroot
  [[ -n "$CHROOT_ONLY" ]] && { enter_chroot "$DEST" /bin/bash; return 0; }

  local REPO=$(get_core_repo_url "$REPO_URL" "$ARCH")
  [[ -z "$DOWNLOAD_DIR" ]] && DOWNLOAD_DIR=$(mktemp -d)
  mkdir -p "$DOWNLOAD_DIR"
  trap "unmount_all '$DEST'; [[ -n '$PRESERVE_DOWNLOAD_DIR' ]] || rm -rf '$DOWNLOAD_DIR'" KILL TERM EXIT
  debug "destination directory: $DEST"
  debug "core repository: $REPO"
  debug "temporary directory: $DOWNLOAD_DIR"
  
  # Fetch packages, install system and do a minimal configuration
  mkdir -p "$DEST"
  local LIST=$(fetch_packages_list $REPO)
  install_pacman_packages "${BASIC_PACKAGES[*]}" "$DEST" "$LIST" "$DOWNLOAD_DIR"
  configure_pacman "$DEST" "$ARCH"
  configure_minimal_system "$DEST"
  install_packages "$ARCH" "$DEST" "${BASIC_PACKAGES[*]} ${EXTRA_PACKAGES[*]}"
  init_keyring "$DEST" # trust package signatures out of the box
  configure_pacman "$DEST" "$ARCH" # Pacman must be re-configured
  restore_pacman_conf "$DEST" "$DOWNLOAD_DIR" # swap temp conf for the official one
  [[ -z "$PRESERVE_DOWNLOAD_DIR" ]] && rm -rf "$DOWNLOAD_DIR"
  
  debug "Done!"
  debug
  debug "Enter the new system (no arch-install-scripts required):"
  debug "$ sudo $(basename "$0") -c $DEST"
  debug "Or, if available: sudo arch-chroot $DEST"
}

main "$@"
