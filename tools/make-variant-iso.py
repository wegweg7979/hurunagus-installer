#!/usr/bin/env python3
"""Give a bootc-image-builder `anaconda-iso` a Hurunagus variant menu.

    tools/make-variant-iso.py --variants variants.conf \\
        --input output/bootiso/install.iso --output output/install-variants.iso

WHY A REPACK IS NEEDED
Anaconda cannot choose a bootc image from its own UI — the image comes from the
kickstart a boot entry points at (Red Hat documents this as a limitation of
image-mode installs).  BIB emits exactly one kickstart and one working boot
entry, so every extra variant has to arrive as an extra entry plus the kickstart
it points at.  That is what this script writes:

  * one kickstart per variant in variants.conf, at the ISO root, so
    `inst.ks=hd:LABEL=<volid>:/<name>.ks` finds it;
  * a menu entry per `pull` variant in BOTH GRUB configs — the BIOS one on the
    ISO9660 (`/boot/grub2/grub.cfg`) and the EFI one inside the FAT image
    (`/EFI/BOOT/grub.cfg` in `images/efiboot.img`), because firmware reads the
    copy inside the FAT image, not the ISO9660 one;
  * BIB's own entries are re-pointed at the `offline` variant's kickstart, so
    every path through the menu goes through a kickstart this repo owns.

The `offline` variant is installed from the payload BIB embedded (no network at
all) and switches its update origin to the registry; if that switch cannot reach
the registry, a oneshot unit retries it at first boot instead of leaving the box
tracking the payload reference forever.  The `pull` variants install straight
from the registry with Anaconda's `bootc` kickstart command.

Requires: xorriso, mtools (mcopy), optionally isomd5sum (implantisomd5).
Needs no root — the FAT image is edited with mcopy rather than by mounting it.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BIOS_CFG = "/boot/grub2/grub.cfg"
EFI_CFG = "/EFI/BOOT/grub.cfg"
EFI_IMG = "/images/efiboot.img"
BASE_KS = "/osbuild-base.ks"
ESP_GUID = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"

# The line BIB writes into its own base kickstart to install the embedded
# payload.  We reproduce it verbatim in the offline kickstart and refuse to run
# if the input ISO does not carry it — otherwise a change in BIB's payload
# layout would silently produce an ISO that installs nothing.
PAYLOAD_REF = "ostreecontainer --url=/run/install/repo/container --transport=oci"

UNIT_NAME = "hurunagus-origin-fix.service"
UNIT_PATH = "/etc/systemd/system/" + UNIT_NAME
MARKER = "/var/lib/hurunagus-origin-fix-attempted"

REF_RE = re.compile(r"^[a-z0-9][a-z0-9.-]*(?::\d+)?/[a-z0-9][a-z0-9._/-]*(?::[A-Za-z0-9._-]+)?$")


def die(msg: str) -> "None":
    print(f"make-variant-iso: error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def note(msg: str) -> None:
    print(f"make-variant-iso: {msg}", flush=True)


def run(cmd: list[str], check: bool = True, env: dict | None = None) -> subprocess.CompletedProcess:
    note("$ " + " ".join(str(c) for c in cmd))
    proc = subprocess.run(cmd, text=True, capture_output=True, env=env)
    if check and proc.returncode != 0:
        sys.stdout.write(proc.stdout or "")
        sys.stderr.write(proc.stderr or "")
        die(f"command failed ({proc.returncode}): {' '.join(str(c) for c in cmd)}")
    return proc


def have(tool: str) -> bool:
    return shutil.which(tool) is not None


def text_of(proc: subprocess.CompletedProcess) -> str:
    """xorriso reports most of what we parse on stderr, so read both streams."""
    return (proc.stdout or "") + (proc.stderr or "")


# ----------------------------------------------------------------- variants


class Variant:
    def __init__(self, address: str, label: str, desktop: str, mode: str, lineno: int):
        self.address = address
        self.label = label
        self.desktop = desktop
        self.mode = mode
        self.lineno = lineno
        self.name = address.split("/")[-1].split(":")[0]

    @property
    def ks_name(self) -> str:
        return f"{self.name}.ks"

    def menu_entry(self, volid: str) -> str:
        return (
            f"menuentry 'Install {self.label} ({self.desktop})' --class fedora --class gnu-linux "
            f"--class gnu --class os {{\n"
            f"\tlinux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL={volid} "
            f"inst.ks=hd:LABEL={volid}:/{self.ks_name} quiet\n"
            f"\tinitrd /images/pxeboot/initrd.img\n"
            f"}}\n"
        )


def read_variants(path: Path) -> list[Variant]:
    variants: list[Variant] = []
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        fields = raw.split("\t")
        if len(fields) != 4:
            die(f"{path}:{lineno}: expected 4 tab-separated fields (address<TAB>label<TAB>desktop<TAB>mode), got {len(fields)}")
        address, label, desktop, mode = (f.strip() for f in fields)
        if not REF_RE.match(address):
            die(f"{path}:{lineno}: '{address}' is not an image address (registry/owner/name[:tag])")
        if mode not in ("offline", "pull"):
            die(f"{path}:{lineno}: mode must be 'offline' or 'pull', got '{mode}'")
        if "nvidia" in address:
            die(f"{path}:{lineno}: '{address}' — this project does not ship vendor-flavoured images")
        variants.append(Variant(address, label, desktop, mode, lineno))
    if not variants:
        die(f"{path}: no variants")
    offline = [v for v in variants if v.mode == "offline"]
    if len(offline) != 1:
        die(f"{path}: exactly one variant must be mode=offline (the image the ISO is built from), found {len(offline)}")
    ks_names = [v.ks_name for v in variants]
    if len(set(ks_names)) != len(ks_names):
        die(f"{path}: two variants map to the same kickstart name: {ks_names}")
    if "osbuild" in " ".join(ks_names):
        die(f"{path}: a variant name would collide with BIB's own kickstart files")
    return variants


# ---------------------------------------------------------------- kickstarts


def retry_unit(address: str) -> str:
    return f"""[Unit]
Description=Point this Hurunagus system at its registry image
Documentation=https://github.com/wegweg7979/hurunagus-installer
After=network-online.target
Wants=network-online.target
ConditionPathExists=!{MARKER}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sh -c 'bootc switch --mutate-in-place --transport registry {address} && touch {MARKER}'
ExecStartPost=/usr/bin/systemctl disable {UNIT_NAME}

[Install]
WantedBy=multi-user.target
"""


def ks_offline(v: Variant) -> str:
    return f"""# Hurunagus installer — {v.label} ({v.address})
# Installs the payload embedded in this ISO, so it needs no network.  The
# update origin is switched to the registry; when that cannot be reached (a
# genuinely offline install) a oneshot unit retries it at first boot, so the
# system ends up tracking the registry image instead of the ISO payload.
{PAYLOAD_REF}
%post
if ! bootc switch --mutate-in-place --transport registry {v.address}; then
  cat >{UNIT_PATH} <<'HURUNAGUS_UNIT'
{retry_unit(v.address)}HURUNAGUS_UNIT
  systemctl enable {UNIT_NAME}
fi
touch {MARKER}
%end
"""


def ks_pull(v: Variant) -> str:
    return f"""# Hurunagus installer — {v.label} ({v.address})
# Installed straight from the registry with Anaconda's `bootc` kickstart
# command (Fedora 43+/RHEL 10): no payload is copied, and the system tracks this
# image from its first boot.  Network is REQUIRED — a failure fails the install
# rather than leaving the wrong distribution on the disk.
bootc --source-imgref=registry:{v.address} --target-imgref={v.address}
"""


def kickstart(v: Variant) -> str:
    return ks_offline(v) if v.mode == "offline" else ks_pull(v)


# ----------------------------------------------------------------------- iso


def iso_volid(iso: Path) -> str:
    out = text_of(run(["xorriso", "-indev", str(iso), "-pvd_info"], check=False))
    m = re.search(r"Volume id\s*:\s*'([^']+)'", out)
    if not m:
        m = re.search(r"Volume Id\s*:\s*(\S+)", text_of(run(["xorriso", "-indev", str(iso), "-pvd_info"], check=False)))
    if not m:
        die(f"cannot read the volume id of {iso}")
    return m.group(1)


def extract(iso: Path, pairs: list[tuple[str, Path]]) -> None:
    cmd = ["xorriso", "-osirrox", "on", "-indev", str(iso)]
    for iso_path, dest in pairs:
        cmd += ["-extract", iso_path, str(dest)]
    run(cmd)


def patch_grub(cfg: str, volid: str, offline: Variant, extras: list[Variant]) -> tuple[str, int]:
    """Re-point BIB's entries at our offline kickstart and insert variant entries."""
    retargeted = cfg.count(f"inst.ks=hd:LABEL={volid}:/osbuild.ks")
    if retargeted == 0:
        die(f"{BIOS_CFG}/{EFI_CFG}: no 'inst.ks=hd:LABEL={volid}:/osbuild.ks' to re-point — unexpected BIB layout")
    cfg = cfg.replace(f"inst.ks=hd:LABEL={volid}:/osbuild.ks", f"inst.ks=hd:LABEL={volid}:/{offline.ks_name}")

    lines = cfg.splitlines(keepends=True)
    first = next((i for i, line in enumerate(lines) if line.startswith("menuentry ")), None)
    if first is None:
        die("no menuentry in the GRUB config — unexpected layout")
    block = "".join(v.menu_entry(volid) + "\n" for v in extras)
    patched = "".join(lines[:first]) + block + "".join(lines[first:])
    return patched, retargeted


def edit_fat_image(img: Path, cfg_text: str, workdir: Path) -> None:
    """Replace ::/EFI/BOOT/grub.cfg inside the EFI FAT image (no root needed)."""
    if not have("mcopy"):
        die("mcopy (mtools) is required to edit the EFI boot image")
    new_cfg = workdir / "grub-efi-new.cfg"
    new_cfg.write_text(cfg_text)
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    run(["mcopy", "-o", "-i", str(img), str(new_cfg), "::/EFI/BOOT/grub.cfg"], env=env)
    listing = run(["mdir", "-i", str(img), "::/EFI/BOOT/grub.cfg"], env=env, check=False)
    if listing.returncode != 0:
        die("mcopy wrote the EFI grub.cfg but mdir cannot read it back")


def repack(iso_in: Path, iso_out: Path, volid: str, ks_files: dict[str, Path],
           bios_cfg: Path, efi_cfg: Path, efi_img: Path) -> None:
    cmd = ["xorriso", "-indev", str(iso_in), "-outdev", str(iso_out),
           "-boot_image", "any", "replay", "-overwrite", "on"]
    for iso_path, src in ((BIOS_CFG, bios_cfg), (EFI_CFG, efi_cfg), (EFI_IMG, efi_img)):
        cmd += ["-update", str(src), iso_path]
    for name, src in ks_files.items():
        cmd += ["-map", str(src), "/" + name]
    # The EFI boot image also lives in appended partition 2; replacing it there is
    # what makes the new config take effect for firmware (same as mkksiso does).
    cmd += ["-append_partition", "2", ESP_GUID, str(efi_img)]
    run(cmd)


def verify(iso_out: Path, volid: str, variants: list[Variant], workdir: Path, md5: bool) -> None:
    out = text_of(run(["xorriso", "-indev", str(iso_out), "-report_el_torito", "plain"]))
    if f"Volume id    : '{volid}'" not in out:
        die(f"output ISO volume id changed (expected '{volid}')")
    if out.count("El Torito boot img :") < 2:
        die("output ISO lost a boot image (BIOS or EFI)")

    listing = text_of(run(["xorriso", "-indev", str(iso_out), "-ls", "/"]))
    for v in variants:
        if f"'{v.ks_name}'" not in listing:
            die(f"{v.ks_name} is not on the output ISO")

    check = workdir / "verify"
    check.mkdir(parents=True, exist_ok=True)
    extract(iso_out, [(BIOS_CFG, check / "bios.cfg"), (EFI_CFG, check / "efi.cfg"), (EFI_IMG, check / "efiboot.img")])
    for name, cfg in (("BIOS", check / "bios.cfg"), ("EFI (ISO9660)", check / "efi.cfg")):
        text = cfg.read_text()
        for v in variants:
            if v.mode == "offline" or v.ks_name == "osbuild.ks":
                continue
            if f"/{v.ks_name}" not in text:
                die(f"{name} grub.cfg has no entry for {v.name}")
        if f"/osbuild.ks" in text:
            die(f"{name} grub.cfg still points at BIB's own kickstart")
        note(f"{name} grub.cfg: {text.count('menuentry ')} entries, all variants present")

    env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    inside = run(["mcopy", "-i", str(check / "efiboot.img"), "::/EFI/BOOT/grub.cfg", str(check / "efi-fat.cfg")], env=env, check=False)
    if inside.returncode != 0:
        die("cannot read the EFI grub.cfg back out of the FAT image")
    fat = (check / "efi-fat.cfg").read_text()
    if not all(f"/{v.ks_name}" in fat for v in variants if v.mode != "offline"):
        die("the EFI FAT image still carries the OLD grub.cfg — firmware would ignore the new entries")
    note("EFI FAT image grub.cfg: updated (this is the copy firmware actually reads)")

    if md5 and have("checkisomd5"):
        proc = run(["checkisomd5", str(iso_out)], check=False)
        if proc.returncode != 0:
            die("checkisomd5 rejects the output ISO")


# ----------------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--variants", type=Path, default=Path("variants.conf"))
    ap.add_argument("--input", type=Path, required=True, help="the anaconda-iso bootc-image-builder produced")
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--workdir", type=Path, default=None, help="keep intermediates here instead of a temp dir")
    ap.add_argument("--no-md5", action="store_true", help="skip implantisomd5 (needed for 'Test this media')")
    ap.add_argument("--dry-run", action="store_true", help="print what would be written and stop")
    args = ap.parse_args()

    if not have("xorriso"):
        die("xorriso is required")
    if not args.input.is_file():
        die(f"no such input ISO: {args.input}")

    variants = read_variants(args.variants)
    offline = next(v for v in variants if v.mode == "offline")
    extras = [v for v in variants if v.mode != "offline"]

    volid = iso_volid(args.input)
    note(f"input  {args.input} (volume id '{volid}')")
    note(f"offline entry installs {offline.address} from the embedded payload")
    for v in extras:
        note(f"menu entry installs {v.address} from the registry")

    workdir = args.workdir or Path(tempfile.mkdtemp(prefix="hurunagus-iso-"))
    workdir.mkdir(parents=True, exist_ok=True)
    extract(args.input, [(BIOS_CFG, workdir / "bios.cfg"), (EFI_CFG, workdir / "efi.cfg"),
                         (EFI_IMG, workdir / "efiboot.img"), (BASE_KS, workdir / "osbuild-base.ks")])

    base_ks = (workdir / "osbuild-base.ks").read_text()
    if PAYLOAD_REF not in base_ks:
        die(f"{BASE_KS} does not carry '{PAYLOAD_REF}' — this ISO was not built by the expected BIB version")
    m = re.search(r"bootc switch --mutate-in-place --transport registry (\S+)", base_ks)
    if not m:
        die(f"cannot tell which image {BASE_KS} switches to")
    built_from = m.group(1)
    if built_from != offline.address:
        die(f"this ISO was built from {built_from}, but variants.conf marks {offline.address} as the offline variant — "
            f"build the ISO from the offline variant, or fix variants.conf")

    ks_files: dict[str, Path] = {}
    for v in variants:
        text = kickstart(v)
        if args.dry_run:
            print(f"\n--- {v.ks_name} ---\n{text}")
        else:
            path = workdir / v.ks_name
            path.write_text(text)
            ks_files[v.ks_name] = path

    for cfg_path, label in ((workdir / "bios.cfg", BIOS_CFG), (workdir / "efi.cfg", EFI_CFG)):
        patched, retargeted = patch_grub(cfg_path.read_text(), volid, offline, extras)
        note(f"{label}: {retargeted} entr{'y' if retargeted == 1 else 'ies'} re-pointed at {offline.ks_name}, "
             f"{len(extras)} variant entr{'y' if len(extras) == 1 else 'ies'} added")
        if not args.dry_run:
            cfg_path.write_text(patched)

    if args.dry_run:
        note("dry run: nothing written")
        return 0

    edit_fat_image(workdir / "efiboot.img", (workdir / "efi.cfg").read_text(), workdir)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    repack(args.input, args.output, volid, ks_files, workdir / "bios.cfg", workdir / "efi.cfg", workdir / "efiboot.img")

    md5 = not args.no_md5
    if md5 and not have("implantisomd5"):
        note("implantisomd5 is missing — the 'Test this media' entry will fail its check; pass --no-md5 to silence this")
        md5 = False
    if md5:
        run(["implantisomd5", str(args.output)])

    verify(args.output, volid, variants, workdir, md5)
    note(f"wrote {args.output} ({args.output.stat().st_size / 2**30:.2f} GiB)")
    note("boot-test it in a VM: BIOS and EFI, and check the installed system with `bootc status`")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
