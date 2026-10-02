# bluetooth-disable-ll-privacy-dkms

A workaround for Intel Wireless-AC 9560 Bluetooth dropping every device at random on Linux
6.14 and later. At each drop the kernel logs:

```
Bluetooth: hci0: Hardware error 0x0c
Bluetooth: hci0: Exception info
```

This is an Arch Linux DKMS package. It rebuilds the kernel's `bluetooth` module with one small
patch that makes the kernel ignore the controller's LL Privacy support. The kernel then resolves
Bluetooth LE private addresses itself, as every kernel up to 6.13 did, and never uses the
firmware code path that crashes.

**Status:** in daily use since 2026-09-25 on a 9560 laptop running the Arch `linux` kernel 7.2.
There have been no resets since. The kernel upgrade from 7.2.6 to 7.2.7 rebuilt the module with no
manual step. Before the patch, the same machine had 3 resets in 22 minutes. The bug is not fixed
upstream yet; see [Upstream](#upstream).

## Are you affected?

You probably are if all of these are true:

- Your Bluetooth controller is Intel "Jefferson Peak" (JfP), USB ID `8087:0aaa`. This is the
  Bluetooth part of the Intel Wireless-AC 9560. The USB ID database lists the same ID for the
  9460 family, which has not been tested.

  ```
  cat /sys/class/bluetooth/hci0/device/../{idVendor,idProduct}   # 8087 and 0aaa
  ```

- You run Linux 6.14 or later (`uname -r`), and 6.13 or earlier did not have the problem.
- The kernel log shows the hardware error at the moments your devices drop:

  ```
  sudo journalctl -k | grep 'Hardware error 0x0c'
  ```

Usually every device reconnects within about a second. Sometimes the reset fails and the adapter
disappears: `hci0` comes back as `hci1`, or it stays gone until `systemctl restart bluetooth` or a
reboot. The crash can happen with nothing connected. Paired Bluetooth LE devices, such as
keyboards and mice, seem to make it more likely.

The package only builds for the Arch `linux` kernel. For other kernels, see
[Other kernels and distributions](#other-kernels-and-distributions).

## Why it happens

Kernel commit [e209e5ccc5ac](https://github.com/torvalds/linux/commit/e209e5ccc5ac)
("Bluetooth: MGMT: Mark LL Privacy as stable") first shipped in 6.14. Since then, the kernel
programs the controller's resolving list and turns on controller-side address resolution whenever
the controller advertises LL Privacy. Before 6.14 this needed an experimental opt-in that was
almost never enabled. The 9560 advertises LL Privacy, and its firmware crashes at random once
this is in use. Its firmware in linux-firmware has not changed since 2024 and does not help.

The same commit also removed a check that kept devices with private addresses out of the
controller's accept list when the host, not the controller, resolves them. Masking LL Privacy
alone would stop those devices from reconnecting on their own, so the patch puts that check back.

## Investigating it yourself

These steps use only the journal, sysfs and the BlueZ tools in `bluez-utils`. They are how this
bug was tracked down. Reading the kernel log needs `sudo`.

### 1. Identify the controller

```
cat /sys/class/bluetooth/hci0/device/../{idVendor,idProduct}   # 8087 and 0aaa for the 9560
sudo journalctl -k -b | grep -i 'hci0:.*firmware'                # firmware file and build loaded
```

For the 9560 the firmware file is `intel/ibt-17-16-1.sfi`.

### 2. Tell a firmware crash from an ordinary disconnect

When a device drops, look at the kernel and bluetoothd messages from that moment together:

```
sudo journalctl -b -o short-precise _TRANSPORT=kernel + _SYSTEMD_UNIT=bluetooth.service
```

This bug shows up as `hci0: Hardware error 0x0c`, then `hci0: Exception info`, then the firmware
loading again as the adapter is reset. Other patterns point to other problems:

- A drop with no hardware error is a normal disconnect, caused by range, interference or the
  device itself.
- `usb …: USB disconnect` for the controller means it fell off the USB bus, which is a USB or
  power problem rather than this one.

To list every firmware crash in the journal, with dates:

```
sudo journalctl -k -o short-iso | grep 'Hardware error'
```

### 3. Rule out the usual suspects

These were all ruled out on the test machine:

- **USB autosuspend.** If `cat /sys/class/bluetooth/hci0/device/../power/control` prints `auto`,
  the controller may be suspended when idle. Keep it awake until the next boot:

  ```
  echo on | sudo tee /sys/class/bluetooth/hci0/device/../power/control
  ```

  If the hardware errors continue, autosuspend is not the cause.
- **System suspend.** Compare the time of each error with the suspend and resume times from
  `sudo journalctl -k | grep -E 'PM: suspend (entry|exit)'`. Errors that only happen right after
  resume point to a different problem.
- **Old firmware.** Update the system. The 9560 firmware has not changed in linux-firmware since
  2024, so this rarely helps, but it is cheap to check.

### 4. Check that LL Privacy is in use

```
btmgmt info
```

On an affected kernel, `ll-privacy` appears under `supported settings`, which means the controller
claims LL Privacy and the kernel will use it. While LE is on, `ll-privacy` also appears under
`current settings`.

The kernel only puts devices in the controller's resolving list if they use private addresses.
These are paired devices that shared an identity resolving key (IRK) when pairing, typically LE
keyboards, mice and some headphones. To list them:

```
sudo grep -l IdentityResolvingKey /var/lib/bluetooth/*/*/info
```

To see what the controller's resolving list currently holds (empty with the package installed):

```
sudo cat /sys/kernel/debug/bluetooth/hci0/resolv_list
```

### 5. Catch the crash in the act

`btmon` records the raw traffic between the kernel and the controller. Leave it recording until
the next drop, then stop it with Ctrl-C and search the capture:

```
sudo btmon -w bt.snoop
btmon -r bt.snoop | grep -nE 'Hardware Error|Resolving List|Address Resolution'
```

The crash is the `Hardware Error` event. The commands just before it show what the controller was
doing when it crashed. Don't share the capture publicly: it contains device addresses and can
contain pairing keys.

### 6. Confirm with the package

Install the package (see [Install](#install)) and keep using your devices as usual. If the
hardware errors stop, LL Privacy was the trigger. To be certain, for example before reporting the
bug upstream, boot once with `bluetooth.disable_ll_privacy=0` on the kernel command line. This
gives the stock behaviour, so the errors should come back.

## What the patch changes

[`pacman-package/bluetooth-disable-ll-privacy.patch`](pacman-package/bluetooth-disable-ll-privacy.patch)
changes two places in `net/bluetooth` and nothing else:

1. It adds the module parameter `bluetooth.disable_ll_privacy`, on by default. When on, the LL
   Privacy bit is cleared as the controller's LE features are read. The resolving list, address
   resolution and privacy modes are then never used, and the kernel logs
   `LL Privacy support masked (disable_ll_privacy=1)`.
2. It restores the pre-6.14 accept-list rule, so LE devices that use private addresses keep
   reconnecting automatically.

`btusb`, `btintel` and the firmware are untouched. The mask applies to every Bluetooth controller
in the machine, not only Intel ones. That is harmless, because it is exactly how 6.13 and earlier
behaved, but there is no reason to install this package if you don't have the crash. To get the
stock behaviour without removing the package, boot with `bluetooth.disable_ll_privacy=0`.

## Install

```
git clone https://github.com/saviocmc/bluetooth-disable-ll-privacy-dkms.git
cd bluetooth-disable-ll-privacy-dkms/pacman-package
makepkg -si
sudo reboot
```

`makepkg -si` installs `dkms`, `git` and `linux-headers` if they are missing. DKMS then builds the
module at the end of the same transaction. The build needs network access, because it downloads
`net/bluetooth` from the [archlinux/linux](https://github.com/archlinux/linux) tag that matches
your kernel.

You can load the new module without rebooting. Bluetooth devices drop for a few seconds while you
do; if a module refuses to unload, reboot instead.

```
sudo systemctl stop bluetooth
for m in btusb btintel bnep rfcomm hidp bluetooth; do sudo modprobe -r $m; done
sudo modprobe btusb
sudo systemctl start bluetooth
```

## Check that it works

```
dkms status bluetooth-disable-ll-privacy                   # bluetooth-disable-ll-privacy/1.0, <kernel>, x86_64: installed
modinfo -n bluetooth                                       # .../updates/dkms/bluetooth.ko.zst
cat /sys/module/bluetooth/parameters/disable_ll_privacy    # Y
btmgmt info | grep -o ll-privacy                           # no output
sudo journalctl -k -b | grep 'LL Privacy support masked'   # one line per controller
```

After that, the only thing that matters is whether the resets stop. You can watch for them live:

```
sudo journalctl -k -f | grep --line-buffered -E 'Hardware error|hci[0-9]'
```

Or count the resets in the current boot, which should stay at 0:

```
sudo journalctl -k -b | grep -c 'Hardware error'
```

## Kernel updates

You don't need to do anything. Before a new `linux` kernel is installed, a pacman hook from this
package fetches that kernel's `net/bluetooth` and checks that the patch applies. You'll see
"Checking that the Bluetooth LL Privacy patch applies to the new kernel..." in the `pacman -Syu`
output. The `dkms` hooks then rebuild the module for the new kernel in the same transaction
("Install DKMS modules") and remove it from the old one.

Each kernel upgrade also prints this warning, which is harmless:

```
warning: could not get file information for usr/lib/modules/<old kernel>/kernel/net/bluetooth/bluetooth.ko.zst
```

When DKMS installs the patched module, it moves the stock one out of the kernel's directory, and it
only puts it back in a hook that runs just before the old kernel is removed. pacman checks disk
space before any hook runs, so at that moment the file is missing and pacman warns about it. The
old kernel is then removed normally.

The check fails if there is no network or if the patch no longer applies to the new kernel. Then
pacman aborts the whole upgrade and nothing changes, so the current kernel keeps the patched
module. You have two ways forward:

- Upgrade everything except the kernel until the patch is updated:

  ```
  sudo pacman -Syu --ignore linux,linux-headers
  ```

- Upgrade the kernel anyway, and accept the stock module on it, by disabling the check for that
  run:

  ```
  sudo mkdir -p /etc/pacman.d/hooks
  sudo ln -s /dev/null /etc/pacman.d/hooks/50-bluetooth-disable-ll-privacy.hook
  sudo pacman -Syu
  sudo rm /etc/pacman.d/hooks/50-bluetooth-disable-ll-privacy.hook
  ```

If the patch stops applying, the upstream code has changed. Check whether the fix has landed
upstream (see [Upstream](#upstream)); if it has, you no longer need this package.

The check does not compile the module, because the new kernel's headers are not installed yet at
that point. If the DKMS build fails after the check has passed, pacman prints a warning and the
new kernel runs the stock module (`modinfo -n bluetooth` points back at `kernel/net/bluetooth/`).
The log is `/var/lib/dkms/bluetooth-disable-ll-privacy/1.0/build/make.log`. Once the cause is
fixed, build the module again:

```
sudo dkms autoinstall
```

## Remove

```
sudo pacman -R bluetooth-disable-ll-privacy-dkms
sudo reboot
```

DKMS puts the stock module back.

## How the package works

The package installs two things: the DKMS recipe and a pacman hook that checks it before kernel
upgrades.

The DKMS recipe is in `/usr/src/bluetooth-disable-ll-privacy-1.0/`: `dkms.conf`, `pre-build.sh`
and the patch. The `dkms` pacman hooks do the rest, once at install time and again for every new
kernel:

1. DKMS copies the recipe to `/var/lib/dkms/bluetooth-disable-ll-privacy/1.0/build/`.
2. `pre-build.sh` does a sparse clone of `net/bluetooth` from the archlinux/linux tag that
   matches the kernel (`7.2.6-arch2-1` becomes `v7.2.6-arch2`, and `7.3.0-arch1-1` becomes
   `v7.3-arch1`), then applies the patch.
3. DKMS builds the module against `linux-headers` and installs it as
   `/usr/lib/modules/<kernel>/updates/dkms/bluetooth.ko.zst`, which takes precedence over the
   stock module. DKMS moves the stock `kernel/net/bluetooth/bluetooth.ko.zst` to
   `/var/lib/dkms/bluetooth-disable-ll-privacy/original_module/` and restores it when the package
   is removed. Until then, `pacman -Qkk linux` reports that one file as missing.

Only kernels named `x.y.z-archN-M`, which come from the `linux` package, are built
(`BUILD_EXCLUSIVE_KERNEL` in `dkms.conf`). `linux-lts`, `linux-zen` and other kernels keep the
stock module.

The pacman hook is `/usr/share/libalpm/hooks/50-bluetooth-disable-ll-privacy.hook`. It runs
before every kernel install or upgrade. It runs `pre-build.sh` for the new kernel in a temporary
directory and aborts the transaction if that fails. Its name sorts it before the `dkms` hooks that
remove the module from the old kernel, and pacman stops at the first failing hook, so an aborted
upgrade leaves the current kernel untouched.

To change the patch, edit it, bump `pkgrel` in `PKGBUILD`, run `updpkgsums`, then run
`makepkg -si` again.

## Other kernels and distributions

The patch is plain `net/bluetooth` code and applies cleanly to at least 6.16 and 7.2. To use it
elsewhere, you have two options:

- Build your kernel with the patch.
- Adapt `pre-build.sh` to fetch `net/bluetooth` from your kernel's source, and change
  `BUILD_EXCLUSIVE_KERNEL` in `dkms.conf` to match your kernel's release names.

## Upstream

When this was checked on 2026-09-26, no kernel had a fix for this. Related reports, none of which
has a fix:

- [kernel bugzilla 220593](https://bugzilla.kernel.org/show_bug.cgi?id=220593)
- StarLabsLtd/firmware [#313](https://github.com/StarLabsLtd/firmware/issues/313),
  [#382](https://github.com/StarLabsLtd/firmware/issues/382),
  [#409](https://github.com/StarLabsLtd/firmware/issues/409)

The proper fix is a kernel quirk that stops the kernel from using LL Privacy on JfP controllers,
or a firmware fix from Intel. This package becomes unnecessary once either one ships.

## License

GPL-2.0-only, the same license as the kernel code that the patch changes. See [LICENSE](LICENSE).
