#!/usr/bin/env bash
# Repack tests for tools/make-variant-iso.py.
#
#   test/test-repack.sh
#
# Runs the tool against a fixture ISO (test/make-fixture-iso.sh) and then AGAINST
# A REAL ISO if one is given in $REAL_ISO — the fixture proves the assertions
# fire on a layout we built, the real ISO proves the layout we built matches what
# bootc-image-builder actually emits.

set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d -t hurunagus-test.XXXXXXXX)
pass=0; fail=0
ok()   { echo "  ok   - $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL - $*"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== fixture =="
test/make-fixture-iso.sh "$work/fixture.iso" Fedora-S-dvd-x86_64-45

# variants.conf as shipped points at hurunagus-hyprland as the offline variant,
# which is exactly what the fixture embeds.
echo "== repack (fixture, offline = hurunagus-hyprland) =="
python3 tools/make-variant-iso.py --variants variants.conf \
    --input "$work/fixture.iso" --output "$work/out.iso" --workdir "$work/wd" --no-md5

xorriso -indev "$work/out.iso" -ls / >"$work/ls.txt" 2>&1 || true
check "offline kickstart on the ISO"        "grep -q \"'hurunagus-hyprland.ks'\" '$work/ls.txt'"
check "pull kickstart (silverblue)"         "grep -q \"'hurunagus-silverblue.ks'\" '$work/ls.txt'"
check "pull kickstart (ublue)"              "grep -q \"'hurunagus-ublue.ks'\" '$work/ls.txt'"
check "still two El Torito boot images"     "xorriso -indev '$work/out.iso' -report_el_torito plain 2>&1 | grep -c 'El Torito boot img :' | grep -qx 2"
check "volume id unchanged"                 "xorriso -indev '$work/out.iso' -report_el_torito plain 2>&1 | grep -q \"Volume id    : 'Fedora-S-dvd-x86_64-45'\""

check "BIOS menu has the variant entries"   "grep -q 'hurunagus-silverblue.ks' '$work/wd/bios.cfg'"
check "BIOS menu no longer uses BIB's ks"   "! grep -q '/osbuild.ks' '$work/wd/bios.cfg'"
check "offline entry re-pointed"            "grep -q 'hurunagus-hyprland.ks' '$work/wd/bios.cfg'"
check "test-media entry re-pointed"         "grep -c 'hurunagus-hyprland.ks' '$work/wd/bios.cfg' | grep -qx 4"
# GRUB boots the first entry after its timeout, so that must be the offline
# variant (no network), and every variant must be named the same way.
check "offline variant keeps the default (first) entry" \
    "awk '/^menuentry /{n++} n==1 && /inst.ks/{print; exit}' '$work/wd/bios.cfg' | grep -q 'hurunagus-hyprland.ks'"
check "the first entry carries the offline variant's label" \
    "grep -qm1 \"menuentry 'Install Hurunagus Hyprland (Hyprland + Omarchy — the flagship)'\" '$work/wd/bios.cfg'"
check "no doubled Install label"            "! grep -q 'Install Install' '$work/wd/bios.cfg' '$work/wd/efi.cfg'"
check "pull entries come after the offline entry" \
    "awk '/^menuentry /{n++} /hurunagus-silverblue.ks/{print n; exit}' '$work/wd/bios.cfg' | grep -qx 2"

# the copy inside the FAT image is what firmware reads
MTOOLS_SKIP_CHECK=1 mcopy -i "$work/wd/efiboot.img" ::/EFI/BOOT/grub.cfg "$work/wd/fat.cfg"
check "EFI FAT image carries the new menu"  "grep -q 'hurunagus-silverblue.ks' '$work/wd/fat.cfg'"

echo "== kickstart contents =="
check "pull ks uses the bootc ks command"   "grep -q 'bootc --source-imgref=registry:ghcr.io/wegweg7979/hurunagus-silverblue:latest --target-imgref=ghcr.io/wegweg7979/hurunagus-silverblue:latest' '$work/wd/hurunagus-silverblue.ks'"
check "pull ks has no ostreecontainer"      "! grep -q ostreecontainer '$work/wd/hurunagus-silverblue.ks'"
check "offline ks installs the payload"     "grep -q 'ostreecontainer --url=/run/install/repo/container --transport=oci' '$work/wd/hurunagus-hyprland.ks'"
check "offline ks retries the switch"       "grep -q 'hurunagus-origin-fix.service' '$work/wd/hurunagus-hyprland.ks'"

echo "== network ISO (--strip-payload) =="
python3 tools/make-variant-iso.py --variants variants.conf --input "$work/fixture.iso" \
    --output "$work/net.iso" --workdir "$work/netwd" --strip-payload --no-md5 >/dev/null
xorriso -indev "$work/net.iso" -ls / >"$work/net-ls.txt" 2>&1 || true
check "payload deleted from the network ISO"  "! grep -q \"'container'\" '$work/net-ls.txt'"
check "BIB's own kickstarts deleted"          "! grep -qE \"'osbuild-base?.ks'\" '$work/net-ls.txt'"
check "variant kickstarts still present"      "grep -q \"'hurunagus-ublue.ks'\" '$work/net-ls.txt'"
check "offline variant still owns the default entry" \
    "awk '/^menuentry /{n++} n==1 && /inst.ks/{print; exit}' '$work/netwd/bios.cfg' | grep -q 'hurunagus-hyprland.ks'"
check "even the default variant now pulls from the registry" \
    "grep -q 'bootc --source-imgref=registry:ghcr.io/wegweg7979/hurunagus-hyprland:latest' '$work/netwd/hurunagus-hyprland.ks'"
check "no variant kickstart on the network ISO installs the payload" \
    "! grep -l ostreecontainer '$work/netwd/hurunagus-hyprland.ks' '$work/netwd/hurunagus-silverblue.ks' '$work/netwd/hurunagus-ublue.ks'"
check "network ISO still bootable (2 el torito images)" \
    "xorriso -indev '$work/net.iso' -report_el_torito plain 2>&1 | grep -c 'El Torito boot img :' | grep -qx 2"
# Sizes are printed, not asserted: on the fixture the payload is ~4 KB, so the
# repack's own overhead dominates and the network ISO comes out slightly larger.
# The real claim (5.81 GiB payload gone → ~1.1 GiB ISO) is gated in CI.
printf '  info - sizes: input %s, full %s, network %s bytes\n' \
    "$(stat -c%s "$work/fixture.iso")" "$(stat -c%s "$work/out.iso")" "$(stat -c%s "$work/net.iso")"

echo "== refusals =="
sed 's/^\(ghcr.io[^\t]*\)\t\(.*\)\toffline$/\1\t\2\tpull/' variants.conf >"$work/no-offline.conf"
check "refuses a variants file with no offline entry" \
    "! python3 tools/make-variant-iso.py --variants '$work/no-offline.conf' --input '$work/fixture.iso' --output '$work/x.iso' 2>/dev/null"
sed 's|ghcr.io/wegweg7979/hurunagus-silverblue:latest|ghcr.io/wegweg7979/hurunagus-silverblue-nvidia:latest|' variants.conf >"$work/nvidia.conf"
check "refuses an nvidia ref" \
    "! python3 tools/make-variant-iso.py --variants '$work/nvidia.conf' --input '$work/fixture.iso' --output '$work/x.iso' 2>/dev/null"
PRODUCT=hurunagus-silverblue BASE_REF=ghcr.io/wegweg7979/hurunagus-silverblue:latest \
    test/make-fixture-iso.sh "$work/other.iso" Fedora-S-dvd-x86_64-45 >/dev/null 2>&1
check "refuses an ISO whose base image is not the offline variant" \
    "! python3 tools/make-variant-iso.py --variants variants.conf --input '$work/other.iso' --output '$work/x.iso' 2>/dev/null"

if [[ -n ${REAL_ISO:-} ]]; then
    echo "== real ISO: $REAL_ISO =="
    xorriso -osirrox on -indev "$REAL_ISO" -extract /osbuild-base.ks "$work/base.ks" >/dev/null 2>&1
    base=$(grep -oE 'bootc switch --mutate-in-place --transport registry \S+' "$work/base.ks" | awk '{print $NF}')
    echo "  base image in the ISO: $base"
    # the variant the ISO was built from becomes the offline entry, the rest pull
    awk -v base="$base" -F'\t' 'BEGIN{OFS="\t"} !/^[[:space:]]*#/ && NF==4 { if ($1==base) $4="offline"; else $4="pull"; print }' \
        variants.conf >"$work/real.conf"
    grep -q offline "$work/real.conf" || bad "could not derive a variants file for the real ISO"
    python3 tools/make-variant-iso.py --variants "$work/real.conf" \
        --input "$REAL_ISO" --output "$work/real-variants.iso" --workdir "$work/realwd" --no-md5
    check "real ISO repacked with a variant menu" \
        "xorriso -indev '$work/real-variants.iso' -report_el_torito plain 2>&1 | grep -c 'El Torito boot img :' | grep -qx 2"
    check "real ISO: variant entries in the BIOS menu" "grep -q 'hurunagus-silverblue.ks' '$work/realwd/bios.cfg'"
    check "real ISO: new menu inside the EFI FAT image" \
        "MTOOLS_SKIP_CHECK=1 mcopy -i '$work/realwd/efiboot.img' ::/EFI/BOOT/grub.cfg '$work/realwd/fat.cfg' && grep -q 'hurunagus-silverblue.ks' '$work/realwd/fat.cfg'"
fi

echo
echo "passed $pass, failed $fail"
[[ $fail -eq 0 ]]
