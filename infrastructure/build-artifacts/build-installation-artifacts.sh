#!/bin/bash

# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#set -x

set -euo pipefail

# Change to the directory where this script is located
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

os_filename=""

# Read the build mode from the make cmd line
# Makefile passes: "$(MODE)" "$(ISO_URL)" "$(ICT_IMG)"
MODE="${1:-image-from-iso}"
ISO_URL="${2:-}"
ICT_IMG="${3:-}"

# Build the micro OS (Alpine) with kernel and initramfs
build-alpine-os(){

echo "Started Alpine OS build!!,it will take some time"

pushd ../micro-os/ || exit 1

if bash build-alpine-os.sh; then
    echo "Alpine OS Build Successful"
else
    echo "Alpine build Failed,Please check!!"
    exit 1
fi
popd > /dev/null || exit 1

}

# Build the CDI GPU spec generator binary (requires Go 1.22+ on host)
build-cdi-generator() {
    CDI_BINARY="../installation-scripts/cdi/intel-cdi-specs-generator-gpu"
    if [ -x "$CDI_BINARY" ]; then
        echo "CDI GPU generator already built, skipping"
    elif ! command -v go >/dev/null 2>&1; then
        echo "WARNING: Go 1.22+ not found — skipping CDI GPU generator build. GPU CDI support will not be available."
    else
        echo "Building CDI GPU spec generator..."
        if bash ../installation-scripts/cdi/build-gpu-generator.sh; then
            echo "CDI GPU generator built successfully"
            if [ -x "$CDI_BINARY" ]; then
                echo "Binary verified - executable"
            else
                echo "WARNING: Binary not executable after build!"
            fi
        else
            echo "WARNING: CDI GPU generator build failed. GPU CDI support will not be available."
        fi
    fi
}

# Download Ubuntu image and build host OS using QEMU + autoinstall
download-Ubuntu_img(){

pushd ../host-os > /dev/null || exit 1

chmod +x prepare-host-img.sh
if [ -z "$ISO_URL" ]; then
    echo "ISO_URL is not provided please check!!!"
    exit 1
fi
bash prepare-host-img.sh -i "$ISO_URL" -c auto-install-pkgs.yaml
if [ "$?" -eq 0 ]; then
    echo "Host OS image created successfully!!"
    os_filename=$(printf "%s\n" *.raw.img.gz 2>/dev/null | head -n 1)
    cp "$os_filename" ../build-artifacts/
else
    echo "Host OS image creation failed, please check!!!"
    popd > /dev/null || exit 1
    exit 1
fi
popd > /dev/null || exit 1
}
# Create alpine-iso
create-alpine-os-iso(){
#Check hook_x86_64.tar.gz file  present under build directory
OUTPUT_DIR="../micro-os/output"
if [[ ! -e "$OUTPUT_DIR/initramfs" && ! -e "$OUTPUT_DIR/vmlinuz" ]]; then
    echo "Looks initrams and kernel files  not presnet, build the Alpine OS first!!"
    exit 1
else
    # Cleanup the files if exist
    if [ -d out ]; then
        rm -rf out
    fi
    mkdir -p out
    cp "$OUTPUT_DIR/initramfs" out/
    cp "$OUTPUT_DIR/vmlinuz" out/
    pushd out/ || exit 1

    # Create the ISO structure
    mkdir -p iso/boot/grub
    mkdir -p iso/EFI/BOOT

    cp vmlinuz  iso/boot/vmlinuz
    cp initramfs iso/boot/initrd

    # Create the grub config file
    cat <<EOF > iso/boot/grub/grub.cfg
        set timeout=0
        set default=0
        set gfxpayload=text
        set gfxmode=text

        menuentry "Alpine Linux" {
	linux /boot/vmlinuz console=tty0 console=ttyS0 ro quite loglevel=3 usbcore.delay_ms=2000 usbcore.autosuspend=-1 modloop=none text
        initrd /boot/initrd
}
EOF
    # Create the bootable iso that support uefi && bios formats
    grub-mkrescue -o alpine-os.iso iso

    if [ "$?" -eq 0 ]; then
        echo "ISO created successfully under $(pwd)"

        # Check number of partitions in the ISO
        echo "Checking partitions in alpine-os.iso..."
        PARTITION_COUNT=$(fdisk -l alpine-os.iso | grep -c "^alpine")
        if [ "$PARTITION_COUNT" -eq 4 ]; then
            echo "ISO partition check passed: 4 partitions found"
        else
            echo "ISO partition check failed: expected 4 partitions, found $PARTITION_COUNT"
            popd >/dev/null || exit 1
        fi
    else
        echo "ISO creation failed,please check!!"
        popd >/dev/null || exit 1
	    exit 1
    fi
    popd >/dev/null || exit 1
fi

}

# Pack the ISO image,Ubuntu Image,config-file
pack-artifacts(){

    os_filename=$(find . -maxdepth 1 -type f \( -name "*.gz" -o -name "*.raw.gz" \) | head -1)
    if [[ -n "$os_filename" ]]; then
        os_filename=$(basename "$os_filename")
        mv "$os_filename" out/
    else
        os_filename=""
    fi
cp bootable-usb-prepare.sh out/
cp config-file out/
cp ven-deployment.sh out/

pushd out > /dev/null || exit 1

echo "Creating usb-bootable-files.tar.gz (ISO + OS image). This can take several minutes..."
# Use pigz for parallel compression (much faster than gzip)
if [[ -n "$os_filename" ]]; then
    tar_cmd="tar -I pigz -cf usb-bootable-files.tar.gz alpine-os.iso $os_filename"
else # for reuse-image mode where OS image is not generated.
    tar_cmd="tar -I pigz -cf usb-bootable-files.tar.gz alpine-os.iso"
fi
if eval "$tar_cmd" > /dev/null; then
    echo "usb-bootable-files.tar.gz created"
    echo "Creating usb-installation-files.tar.gz..."
    # Use pigz for parallel compression
    if tar -I pigz -cf usb-installation-files.tar.gz bootable-usb-prepare.sh config-file usb-bootable-files.tar.gz ven-deployment.sh; then
        echo ""
	echo ""
	echo ""
	# Delete all other generated files other than usb-installation-files.tar.gz
        find . -mindepth 1 -not -name "usb-installation-files.tar.gz" -delete
        echo "##############################################################################################"
        echo "                                                                                              "
        echo "                                                                                              "
        echo "USB Installation files--> usb-installation-files.tar.gz created successfully, under infrastructure/build-artifacts/out"
        echo "                                                                                              "
        echo "                                                                                              "
        echo "###############################################################################################"
    else
	echo "Failed to create usb Installation files, please check!!!"
	popd > /dev/null || exit 1
	exit 1
    fi
else
    echo "usb-bootable-files.tar.gz not created, please check!!!"
    popd > /dev/null || exit 1
    exit 1
fi
popd > /dev/null || exit 1

}

# Use a pre-built ICT image as the OS image
use-ict-image(){

if [ -z "$ICT_IMG" ]; then
    echo "ERROR: ICT_IMG is not provided."
    echo "Usage: make build MODE=image-from-tool ICT_IMG=/path/to/image.raw.gz"
    exit 1
fi

if [ ! -f "$ICT_IMG" ]; then
    echo "ERROR: ICT image not found at: $ICT_IMG"
    echo "Please provide a valid absolute path to the ICT-generated image."
    exit 1
fi

if ! [[ "$ICT_IMG" =~ \.(raw\.gz|raw\.img\.gz)$ ]]; then
    echo "ERROR: ICT image must have a .raw.gz or .raw.img.gz extension (got: $ICT_IMG)"
    exit 1
fi

os_filename=$(basename "$ICT_IMG")
echo "Using ICT image: $ICT_IMG ($(du -h "$ICT_IMG" | awk '{print $1}'))"
if cp "$ICT_IMG" .; then
    echo "ICT image staged for packaging: $os_filename"
else
    echo "ERROR: Failed to copy ICT image into build-artifacts directory."
    exit 1
fi

}

main(){

case "$MODE" in
    image-from-iso)
        echo "Building from ISO. It will take some time Please wait...."
	download-Ubuntu_img
        ;;
    image-from-tool)
        echo "Building using ICT-generated image..."
        use-ict-image
        ;;
    reuse-image)
        echo "Skipping image generation..."
        ;;
    *)
        echo "Invalid mode: $MODE"
        echo "Usage....."
        echo " make build MODE=image-from-iso ISO_URL=http://ubuntu-iso-url"
        echo "or"
        echo " make build MODE=image-from-tool ICT_IMG=/path/to/image.raw.gz"
        echo "or"
        echo " make build MODE=reuse-image"
        exit 1
        ;;
esac

build-cdi-generator

build-alpine-os

create-alpine-os-iso

pack-artifacts

}

######@main#####
main
