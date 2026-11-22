# Hurunagus installer ISO — one ISO for every Hurunagus variant.
#
#   just build          build the anaconda-iso with bootc-image-builder (needs root)
#   just variant-iso    ... and repack it into the multi-variant installer
#   just test           the repack's own tests, against a fixture ISO
#   just check-refs     every variant address is anonymously pullable + known to hurubase
#   just run-vm         boot the finished ISO in a QEMU container
#
# Variants live in variants.conf — one line each, nothing else enumerates them.

export BIB_IMAGE := env_var_or_default("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
image_name := "hurunagus-installer"
iso := "output/iso/hurunagus-installer.iso"
anon_iso := "output/bootiso/install.iso"

# the variant the ISO is built from: the one marked `offline` in variants.conf
offline_ref := `awk -F'\t' '!/^[[:space:]]*#/ && NF==4 && $4=="offline" {print $1}' variants.conf`

# Build the anaconda-iso from the offline variant (rootful podman, like the
# image repos do — bootc-image-builder needs /var/lib/containers/storage).
build:
    #!/usr/bin/env bash
    set -euo pipefail
    ref="{{ offline_ref }}"
    [[ -n $ref ]] || { echo "variants.conf has no offline variant" >&2; exit 1; }
    echo "building anaconda-iso from $ref"
    sudo podman run --rm --privileged --pull=newer --net=host \
        --security-opt label=type:unconfined_t \
        -v "$PWD/disk_config/iso.toml":/config.toml:ro \
        -v "$PWD/output":/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "{{ BIB_IMAGE }}" \
        --type anaconda-iso --use-librepo=True --rootfs=btrfs \
        "$ref"
    sudo chown -R "$USER:$USER" output/
    ls -lh "{{ anon_iso }}"

# Repack the ISO BIB produced into the multi-variant installer.  Runs in a Fedora
# container so xorriso/mtools/isomd5sum match the tools the ISO was built with;
# needs no root (the EFI FAT image is edited with mcopy, not by mounting it).
variant-iso: build
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p output/iso
    podman run --rm -v "$PWD":/work -w /work registry.fedoraproject.org/fedora:45 \
        bash -c 'dnf -y -q install xorriso mtools isomd5sum python3 >/dev/null &&
                 python3 tools/make-variant-iso.py --variants variants.conf \
                     --input '"{{ anon_iso }}"' --output '"{{ iso }}"''
    ls -lh "{{ iso }}"
    echo
    echo "Boot-test BOTH ways before shipping it:"
    echo "  just run-vm            (BIOS)"
    echo "  and an EFI/OVMF boot, then on the installed system: bootc status"

test:
    test/test-repack.sh

# Gate: every address in variants.conf must be (a) anonymously pullable from the
# registry and (b) known to hurubase, so the installer can never offer a variant
# that cannot be installed or that the rebase helper would refuse by name.
check-refs:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    git clone -q --depth=1 https://github.com/wegweg7979/hurunagus-rebase "$tmp/hurubase"
    "$tmp/hurubase/hurubase" --list-refs | sort >"$tmp/known"
    awk -F'\t' '!/^[[:space:]]*#/ && NF==4 {print $1}' variants.conf | sort >"$tmp/variants"
    fail=0
    while read -r ref; do
        printf '%-52s ' "$ref"
        if ! skopeo inspect --no-tags "docker://$ref" >/dev/null 2>&1; then
            echo "NOT anonymously pullable"; fail=1; continue
        fi
        if ! grep -qxF "$ref" "$tmp/known"; then
            echo "pullable, but hurubase does not know it"; fail=1; continue
        fi
        echo "ok"
    done <"$tmp/variants"
    exit $fail

# Boot the finished ISO in a VM (the qemux container the image repos use).
run-vm:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -f {{ iso }} ]] || { echo "no {{ iso }} — run: just variant-iso" >&2; exit 1; }
    port=8006
    while grep -q :$port <<<"$(ss -tunalp)"; do port=$((port + 1)); done
    echo "connect to http://localhost:$port"
    (sleep 20 && xdg-open "http://localhost:$port") &
    podman run --rm --privileged --pull=newer --device=/dev/kvm \
        --publish "127.0.0.1:$port:8006" \
        --env CPU_CORES=4 --env RAM_SIZE=8G --env DISK_SIZE=64G \
        --env TPM=Y --env GPU=Y \
        --volume "$PWD/{{ iso }}":/boot.iso \
        docker.io/qemux/qemu
