#!/usr/bin/env bash
# Build a throwaway ISO laid out like a bootc-image-builder `anaconda-iso`, so
# the variant repack can be tested (and its assertions exercised) without a
# 4-6 GiB image build.  Small: ~25 MiB.
#
#   test/make-fixture-iso.sh <out.iso> [volid]
#
# The layout, and the near-copy of BIB's GRUB configs, are taken from a real ISO
# built by this project (volume id Fedora-S-dvd-x86_64-44):
#
#   /osbuild.ks              BIB's kickstart: %include of the base + the %post
#   /osbuild-base.ks         ostreecontainer --url=/run/install/repo/container
#   /boot/grub2/grub.cfg     BIOS menu (on the ISO9660)
#   /EFI/BOOT/grub.cfg       EFI menu (on the ISO9660; mkefiboot copies it into
#                            the FAT image, which is the copy firmware reads)
#   /images/efiboot.img      20 MiB FAT, appended as El Torito partition 2
#   /images/eltorito.img     BIOS El Torito image
#   /images/pxeboot/{vmlinuz,initrd.img}

set -euo pipefail

out=${1:?usage: make-fixture-iso.sh <out.iso> [volid]}
volid=${2:-Fedora-S-dvd-x86_64-45}
product=${PRODUCT:-hurunagus-hyprland}
base_ref=${BASE_REF:-ghcr.io/wegweg7979/hurunagus-hyprland:latest}

work=$(mktemp -d -t hurunagus-fixture.XXXXXXXX)
trap 'rm -rf "$work"' EXIT
tree=$work/tree

mkdir -p "$tree"/{EFI/BOOT,boot/grub2,images/pxeboot}

# ---- kernel / initrd stand-ins (only their presence matters here)
head -c 4096 /dev/urandom >"$tree/images/pxeboot/vmlinuz"
head -c 4096 /dev/urandom >"$tree/images/pxeboot/initrd.img"

# ---- BIOS El Torito image (4 sectors, what -boot-load-size 4 wants)
head -c 2048 /dev/zero >"$tree/images/eltorito.img"

# ---- the payload stand-in: BIB exports the container image here
mkdir -p "$tree/container/blobs"
printf 'fixture payload\n' >"$tree/container/index.json"

# ---- BIB's kickstarts
printf '%%include /run/install/repo/osbuild-base.ks\n%%post\nbootc switch --mutate-in-place --transport registry %s\n%%end\n' \
    "$base_ref" >"$tree/osbuild.ks"
cat >"$tree/osbuild-base.ks" <<EOF
ostreecontainer --url=/run/install/repo/container --transport=oci
%post --erroronfail
set -e
bootc switch --mutate-in-place --transport registry $base_ref
# used during automatic image testing as finished marker
if [ -c /dev/ttyS0 ]; then
  # continue on errors here, because we used to omit --erroronfail
  echo "Install finished" > /dev/ttyS0 || true
fi
%end
EOF
printf 'fixture\n' >"$tree/.discinfo"

# ---- GRUB menus, copied from the real ISO (BIOS / EFI differ only in load_video)
make_grub() { # $1 = efi|bios
    local insmods
    if [[ $1 == efi ]]; then
        insmods=$'  insmod efi_gop\n  insmod efi_uga\n  insmod video_bochs\n  insmod video_cirrus\n  insmod all_video'
    else
        insmods='  insmod all_video'
    fi
    cat <<EOF

function load_video {
$insmods
}

load_video
set gfxpayload=keep
insmod gzio
insmod part_gpt
insmod ext2
insmod chain

set timeout=60
### END /etc/grub.d/00_header ###

search --no-floppy --set=root -l '$volid'



menuentry 'Install $product 45' --class fedora --class gnu-linux --class gnu --class os {
	linux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=$volid inst.ks=hd:LABEL=$volid:/osbuild.ks quiet
	initrd /images/pxeboot/initrd.img
}

menuentry 'Test this media & install $product 45' --class fedora --class gnu-linux --class gnu --class os {
	linux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=$volid inst.ks=hd:LABEL=$volid:/osbuild.ks rd.live.check quiet
	initrd /images/pxeboot/initrd.img
}


submenu 'Troubleshooting -->' {
	menuentry 'Install $product 45 in basic graphics mode' --class fedora --class gnu-linux --class gnu --class os {
		linux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=$volid inst.ks=hd:LABEL=$volid:/osbuild.ks nomodeset quiet
		initrd /images/pxeboot/initrd.img
	}
	menuentry 'Rescue a $product system' --class fedora --class gnu-linux --class gnu --class os {
		linux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=$volid inst.ks=hd:LABEL=$volid:/osbuild.ks inst.rescue quiet
		initrd /images/pxeboot/initrd.img
	}
	menuentry 'Boot first drive' --class fedora --class gnu-linux --class gnu --class os {
		chainloader (hd0)+1
	}
}
EOF
}
make_grub bios >"$tree/boot/grub2/grub.cfg"
make_grub efi  >"$tree/EFI/BOOT/grub.cfg"

# ---- the EFI FAT image (20 MiB) with its own copy of the EFI menu
efiimg=$work/efiboot.img
truncate -s 20M "$efiimg"
mkfs.vfat -F 16 -n EFIBOOT "$efiimg" >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "$efiimg" ::/EFI ::/EFI/BOOT
head -c 65536 /dev/urandom >"$work/BOOTX64.EFI"
head -c 65536 /dev/urandom >"$work/grubx64.efi"
mcopy -i "$efiimg" "$work/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$efiimg" "$work/grubx64.efi" ::/EFI/BOOT/grubx64.efi
mcopy -i "$efiimg" "$tree/EFI/BOOT/grub.cfg" ::/EFI/BOOT/grub.cfg
cp "$efiimg" "$tree/images/efiboot.img"

# ---- the ISO itself: BIOS + appended ESP, like BIB's
xorrisofs -quiet -R -J -joliet-long -V "$volid" \
    -b images/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e --interval:appended_partition_2:all:: -no-emul-boot \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$efiimg" \
    -isohybrid-gpt-basdat \
    -o "$out" "$tree"

echo "fixture ISO: $out ($(du -h "$out" | cut -f1))"
