# Hurunagus installer

One ISO that installs **any** Hurunagus variant, chosen from the boot menu.

The image repos each build their own installer ISO today; this repo builds the
one that covers them all, and holds the variant list in a single file
(`variants.conf`).

## How the choice works

Anaconda cannot pick a bootc image from its own UI — the image comes from the
kickstart a boot entry points at (a documented limitation of image-mode installs).
So a variant is chosen the same way a distribution is chosen on a multi-boot disc:
by the boot entry.

* the ISO embeds **one** payload: the variant marked `offline`, which installs
  with no network at all and *becomes* the box without pulling anything;
* every other variant gets its own boot entry whose kickstart installs straight
  from the registry with Anaconda's `bootc` kickstart command (Fedora 43+), so
  nothing is copied twice and the system tracks its own image from first boot.

`tools/make-variant-iso.py` produces those entries: it patches **both** GRUB
configs (the BIOS one on the ISO9660 and the EFI one inside `images/efiboot.img`,
which is the copy firmware actually reads), writes one kickstart per variant to
the ISO root, and re-points bootc-image-builder's own entries at the offline
kickstart. It needs no root — the FAT image is edited with `mcopy`, not mounted.

## Variants

| address | desktop | install |
|---|---|---|
| `ghcr.io/wegweg7979/hurunagus-hyprland:latest` | Hyprland + Omarchy (flagship) | offline, from the embedded payload |
| `ghcr.io/wegweg7979/hurunagus-silverblue:latest` | Silverblue + Niri + DMS | from the registry (network) |
| `ghcr.io/wegweg7979/hurunagus-ublue:latest` | uBlue + Niri + DMS | from the registry (network) |

Adding one is a line in `variants.conf` — the kickstarts, the menu and the CI
checks are all generated from it. A KDE variant is the obvious gap: it needs an
image first.

## Building

```bash
just test          # repack tests against a fixture ISO (fast, no root)
just check-refs    # every address is anonymously pullable and known to hurubase
just variant-iso   # build the anaconda-iso, then repack it (needs root/podman)
just run-vm        # boot the result in a QEMU container
```

CI runs the same three gates on every change to `variants.conf`,
`disk_config/`, `tools/` or `test/`, then builds and uploads the ISO.

Boot-test **both** firmware paths (BIOS via `just run-vm`, and an EFI/OVMF boot)
before shipping an ISO: the repack rewrites the EFI boot image, and only a real
boot proves the new menu is what the firmware reads. Then confirm the installed
system with `bootc status` — it must name the variant you chose.

## Notes and limits

* The offline variant switches its update origin to the registry at install time.
  On a genuinely offline install that switch cannot reach the registry, so a
  oneshot unit (`hurunagus-origin-fix.service`) retries it at first boot; until it
  succeeds the box tracks the ISO payload reference rather than `:latest`.
* `pull` variants *require* the network: their kickstart fails the install loudly
  rather than leaving the wrong distribution on the disk.
* Booting this ISO installs; it does not rebase an existing system. To move a
  running box between variants, use [hurubase](https://github.com/wegweg7979/hurunagus-rebase).
* The payload image must ship Fedora's repos in `/etc/yum.repos.d`. Fedora 45 puts
  them in `/usr/share/dnf5/repos.d`, which bootc-image-builder does not read, so the
  ISO build then cannot depsolve the Anaconda environment (`No match for argument:
  coreutils`, no download attempt). Report it as an image bug, not an installer one.
* This repo is the installer only — no image build, no COPR, nothing on a live system.
