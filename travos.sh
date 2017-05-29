#!/usr/bin/env bash

set -euo pipefail

scriptDir="$(dirname "$BASH_SOURCE")"
cd "$scriptDir"
scriptDir="$(pwd)"
resDir="$scriptDir/res"
scratchDir="$scriptDir/scratch"
mkdir -p "$scratchDir"
cleanupTasks=()
cleanup() {
	reverseCleanupTasks=()
	for (( idx=${#cleanupTasks[@]}-1 ; idx>=0 ; idx-- )) ; do
		reverseCleanupTasks+=("${cleanupTasks[idx]}")
	done
	for task in "${reverseCleanupTasks[@]}"; do
		$task || true
	done
	cleanupTasks=()
	if [ "$#" -ne 0 ]; then
		exit "$1"
	fi
}
trap cleanup ERR

if [ "$#" -lt 1 ]; then
	echo "QEMU usage: $0 --test" >&2
	echo "Real usage: $0 /dev/sdX" >&2
	echo "Real+QEMU usage: $0 --test /dev/sdX" >&2
	cleanup 1
fi
device=''
isTest='false'
for arg; do
	if [ "$arg" == --test -o "$arg" == -test ]; then
		isTest='true'
	else
		device="$arg"
	fi
done
if [ "$isTest" == 'true' -a -z "$device" ]; then
	testScratchImage="$scratchDir/test.img"
	rm -f "$testScratchImage"
	truncate -s 128G "$testScratchImage"
	testScratchDevice="$(sudo losetup --show -f "$testScratchImage")"
	device="$testScratchDevice"
	bootDOSPartition="${device}p1"
	bootEFIPartition="${device}p2"
	archPartition="${device}p3"
	homePartition="${device}p4"
	cleanup::testDevice() {
		sudo losetup -d "$testScratchDevice"
	}
	cleanupTasks+=(cleanup::testDevice)
else
	bootDOSPartition="${device}1"
	bootEFIPartition="${device}2"
	archPartition="${device}3"
	homePartition="${device}4"
fi
if [ -z "$device" ]; then
	echo 'Must specify device as /dev/sdX' >&2
	exit 1
fi
if [ ! -e "$device" ]; then
	echo "Device '$device' does not exist." >&2
	exit 1
fi

echo 'Fetching image files...' >&2
imagesDir="$scratchDir/images"
mkdir -p "$imagesDir"
# Syntax: 'URL|TARGET_DIRECTORY|VERIFICATION_FUNCTION|VERIFICATION_FUNCTION_ARGUMENTS'
# VERIFICATION_FUNCTION will be called with arguments <downloaded file> <VERIFICATION_FUNCTION_ARGUMENTS>
images=(
	# Arch: https://mirrors.kernel.org/archlinux/iso/ (bootstrap image)
	"https://mirrors.kernel.org/archlinux/iso/2017.05.01/archlinux-bootstrap-2017.05.01-x86_64.tar.gz|${scratchDir}|verify::gpg_detached|https://mirrors.kernel.org/archlinux/iso/2017.05.01/archlinux-bootstrap-2017.05.01-x86_64.tar.gz.sig|${resDir}/archlinux-key.pgp"
	# Kali Linux: https://www.kali.org/downloads/
	"http://cdimage.kali.org/kali-2017.1/kali-linux-kde-2017.1-amd64.iso|${imagesDir}|verify::sha256|839741fec378114ff068df3ec2dbed9d8e4fae613e690d50b25ce9cc1468104b"
	# Tails: https://tails.boum.org/install/download/openpgp/index.en.html
	"https://25.dl.amnesia.boum.org/tails/stable/tails-i386-2.12/tails-i386-2.12.iso|${imagesDir}|verify::gpg_detached|https://tails.boum.org/torrents/files/tails-i386-2.12.iso.sig|https://tails.boum.org/tails-signing.key"
	# System Rescue CD: http://www.system-rescue-cd.org/Download/
	"https://downloads.sourceforge.net/project/systemrescuecd/sysresccd-x86/5.0.1/systemrescuecd-x86-5.0.1.iso|${imagesDir}|verify::sha256|17f56dc7779d3716539a39a312ddb07d27f2cb1aa55b12420960bd67b00f6c9f"
)

verify::sha256() {
	# Usage: verify::sha256 <file> <sha256>
	if [ "$(sha256sum "$1" | cut -d' ' -f1)" == "$2" ]; then
		return 0
	fi
	return 1
}

verify::gpg_detached() {
	# Usage: verify::gpg_detached <file> <signature file URL> <key file or URL>
	gpgScratchDir="$scratchDir/image-check-gpg-home"
	gpgScratchDirHome="$scratchDir/image-check-gpg-home/gnupg-home"
	rm -rf --one-file-system "$gpgScratchDir"
	mkdir -p -m 700 "$gpgScratchDirHome"
	wget -qO "$gpgScratchDir/signature.sig" "$2"
	if echo "$3" | grep -qP '^https://'; then
		wget -qO- "$3" | gpg --quiet --homedir "$gpgScratchDirHome" --import || true
	else
		cat "$3" | gpg --quiet --homedir "$gpgScratchDirHome" --import || true
	fi
	if gpg --quiet --homedir "$gpgScratchDirHome" --trust-model always --verify "$gpgScratchDir/signature.sig" "$1"; then
		return 0
	fi
	return 1
}

for imageData in "${images[@]}"; do
	imageURL="$(echo "$imageData" | cut -d'|' -f1)"
	imageDownloadDir="$(echo "$imageData" | cut -d'|' -f2)"
	imageVerificationFunction="$(echo "$imageData" | cut -d'|' -f3)"
	imageVerificationFunctionAllArgs="$(echo "$imageData" | cut -d'|' -f4-)"
	imageFilename="$(basename "$imageURL")"
	imageFile="$imageDownloadDir/$imageFilename"
	imageOK='false'
	imageVerificationFunctionArgs=()
	while [ -n "$imageVerificationFunctionAllArgs" ]; do
		imageVerificationFunctionArgs+=("$(echo "$imageVerificationFunctionAllArgs" | cut -d'|' -f1)")
		if echo "$imageVerificationFunctionAllArgs" | grep -qF '|'; then
			imageVerificationFunctionAllArgs="$(echo "$imageVerificationFunctionAllArgs" | cut -d'|' -f2-)"
		else
			imageVerificationFunctionAllArgs=''
		fi
	done
	echo "Grabbing and verifying image '$imageFilename'..." >&2
	while [ "$imageOK" != 'true' ]; do
		while [ ! -f "$imageFile" ]; do
			wget -qO "$imageFile" "$imageURL"
		done
		if "$imageVerificationFunction" "$imageFile" "${imageVerificationFunctionArgs[@]}"; then
			imageOK='true'
		else
			rm "$imageFile"
		fi
	done
	echo "Image verified: '$imageFilename'." >&2
done

# Partition 1: MSDOS boot, 32M,  fat32, ID B007-0D05 "boot dos"
# Partition 2: EFI boot,   ~8G,  fat32, ID B007-0EF1 "boot efi"
# Partition 3: Arch,       48GB, ext4, UUID a5c8a5c8-a5c8-a5c8-a5c8-a5c8a5c8a5c8 "arch"
# Partition 4: Home,       rest, ext4, UUID 803e803e-803e-803e-803e-803e803e803e "home"
bootDOSID='B0070D05'     # As specified to mkfs.fat32
bootDOSUUID='B007-0D05'  # As listed in /dev/disk/by-uuid.
bootEFIID='B0070EF1'     # As specified to mkfs.fat32
bootEFIUUID='B007-0EF1'  # As listed in /dev/disk/by-uuid.
archUUID='a5c8a5c8-a5c8-a5c8-a5c8-a5c8a5c8a5c8'
homeUUID='803e803e-803e-803e-803e-803e803e803e'

echo 'Creating new partitions...' >&2
# Typecode EF02 is from https://www.gnu.org/software/grub/manual/html_node/BIOS-installation.html
sudo sgdisk --clear                       \
	--new=1:1M:2M   --typecode=1:EF02 \
	--new=2:4M:8G   --typecode=2:EF00 \
	--new=3:9G:60G  --typecode=3:8300 \
	--largest-new=4 --typecode=4:8300 \
	--hybrid=1,2,3                    \
	--attributes=1:set:2              \
	--print "$device"
sudo partprobe "$device"
echo 'Creating filesystems...' >&2
sudo mkfs.vfat -i   "$bootDOSID"                       "$bootDOSPartition" 2>/dev/null
sudo mkfs.vfat -i   "$bootEFIID"                       "$bootEFIPartition" 2>/dev/null
sudo mkfs.ext4 -qFU "$archUUID" -O '^has_journal'      "$archPartition"    2>/dev/null
sudo mkfs.ext4 -qFU "$homeUUID" -O '^has_journal' -m 0 "$homePartition"    2>/dev/null
sudo partprobe "$device"
bootEFIDevice="/dev/disk/by-uuid/$bootEFIUUID"
archDevice="/dev/disk/by-uuid/$archUUID"
homeDevice="/dev/disk/by-uuid/$homeUUID"
if [ ! -e "$bootEFIDevice" ]; then
	echo "Cannot find boot EFI device '$bootEFIDevice'." >&2
	cleanup 1
fi
if [ ! -e "$archDevice" ]; then
	echo "Cannot find boot device '$archDevice'." >&2
	cleanup 1
fi
if [ ! -e "$homeDevice" ]; then
	echo "Cannot find boot device '$homeDevice'." >&2
	cleanup 1
fi
mountpointDir="$scratchDir/mnt"
bootEFIMountpoint="$mountpointDir/boot-efi"
archMountpoint="$mountpointDir/arch"
homeMountpoint="$mountpointDir/home"
mkdir -p "$bootEFIMountpoint" "$archMountpoint" "$homeMountpoint"
cleanup::unmount_partitions() {
	sudo umount -l "$bootEFIMountpoint" 2>/dev/null || true
	sudo umount -l "$archMountpoint"    2>/dev/null || true
	sudo umount -l "$homeMountpoint"    2>/dev/null || true
}
cleanupTasks+=(cleanup::unmount_partitions)

echo 'Preparing boot partitions...' >&2
sudo mount "$bootEFIDevice" "$bootEFIMountpoint"
bootDirectory="$bootEFIMountpoint/boot"
efiISODirectory="$bootEFIMountpoint/isos"
efiBinDirectory="$bootEFIMountpoint/bin"
sudo mkdir -p "$bootDirectory" "$efiISODirectory" "$efiBinDirectory"
sudo chown root:root "$bootDirectory" "$efiISODirectory" "$efiBinDirectory"
echo 'Installing GRUB for EFI...' >&2
sudo grub-install --target=x86_64-efi --efi-directory="$bootEFIMountpoint" --boot-directory="$bootDirectory" --removable --recheck
echo 'Installing GRUB for lagecy booting...' >&2
sudo grub-install --target=i386-pc --recheck --boot-directory="$bootDirectory" --removable "$device"
sudo partprobe "$device"
if [ "$(cat /proc/sys/vm/dirty_background_bytes)" -eq 0 ]; then
	# This can slow the system down a lot by dirtying pages, so apply saner values.
	# See https://lwn.net/Articles/572911/
	sudo bash -c 'echo $((16*1024*1024)) > /proc/sys/vm/dirty_background_bytes'
	sudo bash -c 'echo $((48*1024*1024)) > /proc/sys/vm/dirty_bytes'
fi
echo 'Copying live Linux images...' >&2
sudo cp -r "$scriptDir/boot"/* "$bootDirectory/"
sudo rsync -h --inplace --progress --bwlimit=16M "$imagesDir"/*.iso "$efiISODirectory/"
sudo chown -R root:root "$efiISODirectory" "$efiBinDirectory"
sudo umount -l "$bootEFIMountpoint"
sudo sync

qemu::launch() {
	sudo qemu-system-x86_64 -enable-kvm -localtime -m 4G -vga std -drive file="$device",cache=none,format=raw,if=virtio "$@"
}

if [ "$isTest" == 'true' ]; then
	echo 'Launching QEMU...' >&2
	qemu::launch
fi
cleanup 0
