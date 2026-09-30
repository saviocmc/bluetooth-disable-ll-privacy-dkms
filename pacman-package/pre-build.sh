#!/bin/bash
# DKMS PRE_BUILD step: fetch net/bluetooth for the kernel being built and apply the patch.
# DKMS runs it as root from /var/lib/dkms/bluetooth-disable-ll-privacy/<version>/build/, a copy of
# /usr/src/bluetooth-disable-ll-privacy-<version>/ (dkms.conf, this script, the patch). Needs git and network.
# The pacman pre-check (precheck.sh) also runs it, with a temporary <dest-dir>.
# Usage: pre-build.sh <kernel-release> [<dest-dir>]      e.g. pre-build.sh 7.2.6-arch2-1
set -euo pipefail
export GIT_TERMINAL_PROMPT=0
kver=${1:?usage: pre-build.sh <kernel-release> [<dest-dir>]}
tag="v${kver%-*}"                  # 7.2.6-arch2-1 -> v7.2.6-arch2 (tag in archlinux/linux)
# x.y.0 kernels are tagged without the .0: 7.3.0-arch1-1 -> v7.3-arch1
[[ $tag =~ ^(v[0-9]+\.[0-9]+)\.0(-.+)$ ]] && tag=${BASH_REMATCH[1]}${BASH_REMATCH[2]}
here=$(cd "$(dirname "$0")" && pwd)
src=${2:-$here/src}                # DKMS builds from ./src (dkms.conf)
repo=https://github.com/archlinux/linux.git

rm -rf "$src"
echo "fetching net/bluetooth from $repo tag $tag"
git -c advice.detachedHead=false clone -q --filter=blob:none --depth 1 --branch "$tag" --sparse "$repo" "$src"
git -C "$src" sparse-checkout set net/bluetooth
echo "applying bluetooth-disable-ll-privacy.patch"
git -C "$src" apply --verbose "$here/bluetooth-disable-ll-privacy.patch"
