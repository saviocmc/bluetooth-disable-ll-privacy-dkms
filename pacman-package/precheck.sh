#!/bin/bash
# pacman PreTransaction hook (50-bluetooth-disable-ll-privacy.hook), installed as
# /usr/share/libalpm/scripts/bluetooth-disable-ll-privacy-precheck. Before a kernel is installed,
# runs pre-build.sh for it in a temporary directory: fetch its net/bluetooth and apply the patch.
# If that fails, exits 1 so pacman aborts the whole transaction; otherwise DKMS would fail after
# the fact and the new kernel would run the stock module. Compiling is left to DKMS, since the new
# kernel's headers are not installed yet.
# Reads the matched targets on stdin: usr/lib/modules/<kernel-release>/vmlinuz
set -uo pipefail
srcdir=/usr/src/bluetooth-disable-ll-privacy-@PKGVER@
exclusive=$(sed -n 's/^BUILD_EXCLUSIVE_KERNEL="\(.*\)"$/\1/p' "$srcdir/dkms.conf")
failed=()

while read -r target; do
  kver=${target#usr/lib/modules/}
  kver=${kver%/vmlinuz}
  [[ $kver =~ $exclusive ]] || continue   # DKMS skips this kernel too (linux-lts, ...)
  tmp=$(mktemp -d)
  if "$srcdir/pre-build.sh" "$kver" "$tmp/src" </dev/null >"$tmp/log" 2>&1; then
    echo "bluetooth-disable-ll-privacy: the patch applies to $kver"
  else
    cat "$tmp/log"
    failed+=("$kver")
  fi
  rm -rf "$tmp"
done

((${#failed[@]} == 0)) && exit 0
cat <<MSG
==> ERROR: bluetooth-disable-ll-privacy: could not fetch net/bluetooth or apply the patch for
    ${failed[*]}. That kernel would run the stock bluetooth module, so the transaction was
    aborted and nothing was changed. To upgrade everything except the kernel:
      pacman -Syu --ignore linux,linux-headers
    To upgrade the kernel anyway, disable this check (remove the link afterwards):
      mkdir -p /etc/pacman.d/hooks
      ln -s /dev/null /etc/pacman.d/hooks/50-bluetooth-disable-ll-privacy.hook
MSG
exit 1
