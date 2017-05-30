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
unexpected_cleanup() {
	msg 'Unexpected error occurred. Performing cleanup.' >&2 || true
	cleanup 2
}
trap unexpected_cleanup ERR

tempDir="$(umask 077 && mktemp -d)"
cleanup::tempDir() {
	rm -rf --one-file-system "$tempDir"
}
cleanupTasks+=(cleanup::tempDir)

msg() {
	echo ">> $@" >&2
}

usage() {
	echo "        QEMU usage: $0 --config=my-config.cfg --test" >&2
	echo "        Real usage: $0 --config=my-config.cfg /dev/sdX" >&2
	echo "   Real+QEMU usage: $0 --config=my-config.cfg --test /dev/sdX" >&2
	echo '' >&2
	echo '   Other options:' >&2
	echo '     --debug                Set Bash -x option (print all commands as they run).' >&2
	echo '     --assume-formatted     If set, do not recreate partitions on the device.' >&2
	echo '     --skip-verification    If set, downloaded images are not verified for integrity.' >&2
	cleanup 1
}

device=''
isTest='false'
skipImageVerification='false'
assumeFormatted='false'
configFile=''
nextArgIsConfigFile='false'
for arg; do
	if [ "$nextArgIsConfigFile" == 'true' ]; then
		configFile="$arg"
		nextArgIsConfigFile='false'
	elif [ "$arg" == --test -o "$arg" == -test ]; then
		isTest='true'
	elif [ "$arg" == --config -o "$arg" == -config ]; then
		nextArgIsConfigFile='true'
	elif echo "$arg" | grep -qiP '^--?config=.+$'; then
		configFile="$(echo "$arg" | cut -d'=' -f2-)"
	elif [ "$arg" == --debug -o "$arg" == -debug ]; then
		set -x
	elif [ "$arg" == --skip-verification -o "$arg" == -skip-verification ]; then
		skipImageVerification='true'
	elif [ "$arg" == --assume-formatted -o "$arg" == -assume-formatted ]; then
		assumeFormatted='true'
	else
		device="$arg"
	fi
done
if [ -z "$configFile" ]; then
	msg 'Must specify a config file with --config.'
	usage
fi
if [ ! -f "$configFile" ]; then
	msg "Config file '$configFile' does not exist or is not a file."
	usage
fi
if [ "$isTest" == 'true' -a -z "$device" ]; then
	if [ "$assumeFormatted" == 'true' ]; then
		msg '--assume-formatted is incompatible with local testing mode.'
		usage
	fi
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
	msg 'Must specify device as /dev/sdX'
	usage
fi
if [ ! -e "$device" ]; then
	msg "Device '$device' does not exist."
	usage
fi
refreshPartitions() {
	sudo partprobe "$device"
}
refreshPartitions

msg "Reading configuration '$configFile'..."
LUKS_PASSWORD=''
LUKS_KEYFILE=''
PROVISIONING_DIR=''
source "$configFile"
if [ -z "$LUKS_PASSWORD" -a -z "$LUKS_KEYFILE" ]; then
	msg 'Config file must specify at least one of LUKS_PASSWORD, LUKS_KEYFILE.'
	cleanup 1
fi
if [ -n "$LUKS_KEYFILE" -a ! -f "$LUKS_KEYFILE" ]; then
	msg "LUKS_KEYFILE '$LUKS_KEYFILE' does not exist or is not a file."
	cleanup 1
fi
if [ -z "$PROVISIONING_DIR" ]; then
	msg "Config file must specify PROVISIONING_DIR."
	cleanup 1
fi
if [ ! -d "$PROVISIONING_DIR" ]; then
	msg "PROVISIONING_DIR '$PROVISIONING_DIR' does not exist or is not a directory."
	cleanup 1
fi

msg 'Fetching image files...'
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
	msg "Grabbing and verifying image '$imageFilename'..."
	while [ "$imageOK" != 'true' ]; do
		while [ ! -f "$imageFile" ]; do
			wget -qO "$imageFile" "$imageURL"
		done
		if [ "$skipImageVerification" == 'true' ]; then
			imageOK='true'
			continue
		fi
		if "$imageVerificationFunction" "$imageFile" "${imageVerificationFunctionArgs[@]}"; then
			imageOK='true'
		else
			rm "$imageFile"
		fi
	done
	if [ "$skipImageVerification" == 'true' ]; then
		msg "Image verification skipped: '$imageFilename'."
	else
		msg "Image verified: '$imageFilename'."
	fi
done

# Partition 1: MSDOS boot, 32M,  fat32, ID B007-0D05 "boot dos"
# Partition 2: EFI boot,   ~8G,  fat32, ID B007-0EF1 "boot efi"
# Partition 3: Arch,       48GB, ext4, UUID a5c8a5c8-a5c8-a5c8-a5c8-a5c8a5c8a5c8 "arch"
# Partition 4: Home,       rest, ext4, UUID 803e803e-803e-803e-803e-803e803e803e "home"
bootDOSID='B0070D05'     # As specified to mkfs.fat32
bootDOSUUID='B007-0D05'  # As listed in /dev/disk/by-uuid.
bootEFIID='B0070EF1'     # As specified to mkfs.fat32
bootEFIUUID='B007-0EF1'  # As listed in /dev/disk/by-uuid.
archLUKSUUID='0075a105-1035-a5c8-0000-deadbeefcafe'
archRealUUID='0075a105-5ea1-a5c8-0000-deadbeefcafe'
homeLUKSUUID='0075a105-1035-803e-0000-deadbeefcafe'
homeRealUUID='0075a105-5ea1-803e-0000-deadbeefcafe'

ifNotFormatted() {
	if [ "$assumeFormatted" == 'false' ]; then
		"$@"
	fi
}
ifNotFormatted msg 'Creating new partitions...'
# Typecode EF02 is from https://www.gnu.org/software/grub/manual/html_node/BIOS-installation.html
ifNotFormatted sudo sgdisk --clear           \
	--new=1:1M:2M   --typecode=1:EF02 \
	--new=2:4M:8G   --typecode=2:EF00 \
	--new=3:9G:60G  --typecode=3:8300 \
	--largest-new=4 --typecode=4:8300 \
	--hybrid=1,2,3                    \
	--attributes=1:set:2              \
	"$device" 2>/dev/null
ifNotFormatted refreshPartitions
ifNotFormatted msg 'Creating filesystems...'
ifNotFormatted sudo mkfs.vfat -i "$bootDOSID" "$bootDOSPartition" &>/dev/null
ifNotFormatted sudo mkfs.vfat -i "$bootEFIID" "$bootEFIPartition" &>/dev/null
ifNotFormatted refreshPartitions
bootEFIDevice="/dev/disk/by-uuid/$bootEFIUUID"
if [ ! -e "$bootEFIDevice" ]; then
	msg "Cannot find boot EFI device '$bootEFIDevice'."
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

msg 'Preparing boot partitions...'
sudo mount "$bootEFIDevice" "$bootEFIMountpoint"
bootDirectory="$bootEFIMountpoint/boot"
efiISODirectory="$bootEFIMountpoint/isos"
efiBinDirectory="$bootEFIMountpoint/bin"
sudo mkdir -p "$bootDirectory" "$efiISODirectory" "$efiBinDirectory"
sudo chown root:root "$bootDirectory" "$efiISODirectory" "$efiBinDirectory"
ifNotFormatted msg 'Installing GRUB for EFI...'
ifNotFormatted sudo grub-install --target=x86_64-efi --efi-directory="$bootEFIMountpoint" --boot-directory="$bootDirectory" --removable --recheck
ifNotFormatted msg 'Installing GRUB for legacy booting...'
ifNotFormatted sudo grub-install --target=i386-pc --recheck --boot-directory="$bootDirectory" --removable "$device"
ifNotFormatted refreshPartitions
if [ "$(cat /proc/sys/vm/dirty_background_bytes)" -eq 0 ]; then
	# This can slow the system down a lot by dirtying pages, so apply saner values.
	# See https://lwn.net/Articles/572911/
	sudo bash -c 'echo $((16*1024*1024)) > /proc/sys/vm/dirty_background_bytes'
	sudo bash -c 'echo $((48*1024*1024)) > /proc/sys/vm/dirty_bytes'
fi
msg 'Copying live Linux images...'
sudo cp -r "$scriptDir/boot"/* "$bootDirectory/"
for sourceISOFile in "$imagesDir"/*.iso; do
	targetISOFile="$efiISODirectory/$(basename "$sourceISOFile")"
	if [ -f "$targetISOFile" ]; then
		if [ "$skipImageVerification" == 'true' ]; then
			msg "Existing ISO '$(basename "$sourceISOFile")' detected, but image verification is off; assuming image is correct."
		else
			msg "Existing ISO '$(basename "$sourceISOFile")' detected, syncing..."
			sudo rsync -cth --inplace --progress "$sourceISOFile" "$targetISOFile"
		fi
	else
		sudo rsync -th --inplace --progress --bwlimit=16M "$sourceISOFile" "$targetISOFile"
	fi
done
sudo chown -R root:root "$efiISODirectory" "$efiBinDirectory"
sudo umount -l "$bootEFIMountpoint"
sudo sync

msg 'Preparing Arch partitions...'
tempLUKSKeyFile1="$tempDir/luks1.key"
tempLUKSKeyFile2="$tempDir/luks2.key"
touch "$tempLUKSKeyFile1" "$tempLUKSKeyFile2"
cleanup::tempLUKSKeyFiles() {
	rm -f "$tempLUKSKeyFile1" "$tempLUKSKeyFile2"
}
cleanupTasks+=(cleanup::tempLUKSKeyFiles)
chmod 600 "$tempLUKSKeyFile1" "$tempLUKSKeyFile2"
if [ -z "$LUKS_KEYFILE" ]; then
	echo -n "$LUKS_PASSWORD" > "$tempLUKSKeyFile1"
else
	cat "$LUKS_KEYFILE" > "$tempLUKSKeyFile1"
fi
luksFormat() {
	# Usage: luksFormat <UUID> <device>
	sudo cryptsetup luksFormat --batch-mode --key-file="$tempLUKSKeyFile1" --use-random --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --uuid="$1" "$2"
	if [ -n "$LUKS_KEYFILE" -a -n "$LUKS_PASSWORD" ]; then
		echo -n "$LUKS_PASSWORD" > "$tempLUKSKeyFile2"
		sudo cryptsetup luksAddKey --batch-mode --key-file="$tempLUKSKeyFile1" --iter-time 5000 "$2" "$tempLUKSKeyFile2"
	fi
	refreshPartitions
}
ifNotFormatted luksFormat "$archLUKSUUID" "$archPartition"
ifNotFormatted luksFormat "$homeLUKSUUID" "$homePartition"
archLUKSDevice="/dev/disk/by-uuid/$archLUKSUUID"
homeLUKSDevice="/dev/disk/by-uuid/$homeLUKSUUID"
if [ ! -e "$archLUKSDevice" ]; then
	msg "Cannot find arch device '$archLUKSDevice'."
	cleanup 1
fi
if [ ! -e "$homeLUKSDevice" ]; then
	msg "Cannot find home device '$homeLUKSDevice'."
	cleanup 1
fi
cleanup::closeLUKS() {
	sudo cryptsetup luksClose travos-arch || true
	sudo cryptsetup luksClose travos-home || true
}
cleanupTasks+=(cleanup::closeLUKS)
sudo cryptsetup open --key-file="$tempLUKSKeyFile1" "$archPartition" travos-arch
sudo cryptsetup open --key-file="$tempLUKSKeyFile1" "$homePartition" travos-home
archMappedPartition='/dev/mapper/travos-arch'
homeMappedPartition='/dev/mapper/travos-home'
ifNotFormatted sudo mkfs.ext4 -qFU "$archRealUUID" -O '^has_journal'      "$archMappedPartition" 2>/dev/null
ifNotFormatted sudo mkfs.ext4 -qFU "$homeRealUUID" -O '^has_journal' -m 0 "$homeMappedPartition" 2>/dev/null
ifNotFormatted refreshPartitions

qemu::launch() {
	sudo qemu-system-x86_64 -enable-kvm -localtime -m 4G -vga std -drive file="$device",cache=none,format=raw,if=virtio "$@" 2>&1 | (grep --line-buffered -vP '^$|Gtk-WARNING' || cat)
}

if [ "$isTest" == 'true' ]; then
	msg 'Launching QEMU...'
	qemu::launch
fi
msg 'All done.'
cleanup 0
