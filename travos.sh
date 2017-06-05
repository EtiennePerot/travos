#!/usr/bin/env bash

set -euo pipefail

scriptDir="$(dirname "$BASH_SOURCE")"
cd "$scriptDir"
scriptDir="$(pwd)"
resDir="$scriptDir/res"
scratchDir="$scriptDir/scratch"
mkdir -p "$scratchDir"
scratchDir="$(readlink -e "$(cd "$scratchDir" && pwd)")"
isDebug='false'

msg() {
	echo ">> $@" >&2
}

cleanupTasks=()
cleanup() {
	if [ "$isDebug" == 'true' ]; then
		msg 'Going to clean up in 3 minutes... Ctrl+C to interrupt.'
		sleep 3m
	fi
	msg 'Cleaning up...'
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
	msg 'Re-run with --debug to see if it happens again and to figure out where.' >&2 || true
	cleanup 2
}
trap unexpected_cleanup ERR

tempDir="$(umask 077 && mktemp -d)"
cleanup::tempDir() {
	rm -rf --one-file-system "$tempDir"
}
cleanupTasks+=(cleanup::tempDir)

tryAFewTimes() {
	for i in $(seq 1 5); do
		if "$@"; then
			return 0
		else
			echo "[$i]: Retrying command: $@"
		fi
	done
	"$@"
}

for neededBinary in sudo truncate sha256sum gpg wget sgdisk mkfs.vfat mkfs.ext4 partprobe losetup grub-install ionice bsdtar rsync cryptsetup qemu-system-x86_64 ansible-playbook; do
	if ! which "$neededBinary" &> /dev/null; then
		msg "'$neededBinary' was not found in PATH. Please install it."
		cleanup 3
	fi
done

usage() {
	echo "        QEMU usage: $0 --config=my-config.cfg --test"                                  >&2
	echo "        Real usage: $0 --config=my-config.cfg /dev/sdX"                                >&2
	echo "   Real+QEMU usage: $0 --config=my-config.cfg --test /dev/sdX"                         >&2
	echo ''                                                                                      >&2
	echo '   Other options:'                                                                     >&2
	echo '     --debug                Set Bash -x option (print all commands as they run).'      >&2
	echo '     --reprovision          Update an existing key and re-run Ansible provisioning.'   >&2
	echo '     --skip-verification    If set, downloaded images are not verified for integrity.' >&2
	cleanup 1
}

device=''
isTest='false'
skipImageVerification='false'
reprovision='false'
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
		isDebug='true'
		set -x
	elif [ "$arg" == --skip-verification -o "$arg" == -skip-verification ]; then
		skipImageVerification='true'
	elif [ "$arg" == --reprovision -o "$arg" == -reprovision ]; then
		reprovision='true'
	elif [ "$arg" == --help -o "$arg" == -help -o "$arg" == -h ]; then
		usage
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
	if [ "$reprovision" == 'true' ]; then
		msg '--reprovision is incompatible with local testing mode.'
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
PROVISIONING_PRIVATE_KEY=''
PROVISIONING_PUBLIC_KEY=''
ANSIBLE_ROLES_PATH=()
ANSIBLE_ROLES=()
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
if [ -z "$PROVISIONING_PRIVATE_KEY" ]; then
	msg "Config file must specify PROVISIONING_PRIVATE_KEY."
	cleanup 1
fi
if [ ! -f "$PROVISIONING_PRIVATE_KEY" ]; then
	msg "PROVISIONING_PRIVATE_KEY '$PROVISIONING_PRIVATE_KEY' does not exist or is not a file."
	cleanup 1
fi
if [ -z "$PROVISIONING_PUBLIC_KEY" ]; then
	msg "Config file must specify PROVISIONING_PUBLIC_KEY."
	cleanup 1
fi
if [ ! -f "$PROVISIONING_PUBLIC_KEY" ]; then
	msg "PROVISIONING_PUBLIC_KEY '$PROVISIONING_PUBLIC_KEY' does not exist or is not a file."
	cleanup 1
fi
ansibleRolesPath="$scriptDir/ansible/roles"
ansibleRoles='travos'
for ansibleRolePath in "${ANSIBLE_ROLES_PATH[@]}"; do
	if [ ! -d "$ansibleRolePath" ]; then
		msg "Ansible role path '$ansibleRolePath' does not exist or is not a directory."
		cleanup 1
	fi
	ansibleRolesPath="${ansibleRolesPath}:${ansibleRolePath}"
done
for ansibleRole in "${ANSIBLE_ROLES[@]}"; do
	ansibleRoles="${ansibleRoles}, $ansibleRole"
done

msg 'Cleaning up previous runs...'
cleanup::closeLUKS() {
	sudo cryptsetup luksClose travos-arch &> /dev/null || true
	sudo cryptsetup luksClose travos-home &> /dev/null || true
}
cleanup::recursiveCatchAllUnmount() {
	while cut -d' ' -f2 /proc/mounts | grep -qF "$scratchDir"; do
		cleanup::closeLUKS || true
		oneSuccess='false'
		while read mountPoint; do
			if sudo umount -l "$mountPoint" 2> /dev/null; then
				oneSuccess='true'
			fi
		done < <(cut -d' ' -f2 /proc/mounts | grep -F "$scratchDir" | sort -dr)
		if [ "$oneSuccess" == 'false' ]; then
			break
		fi
	done
	cleanup::closeLUKS || true
}
cleanupTasks+=(cleanup::recursiveCatchAllUnmount)
cleanup::recursiveCatchAllUnmount || true

msg 'Fetching image files...'
imagesDir="$scratchDir/images"
mkdir -p "$imagesDir"
archVersion='2017.06.01'
# Syntax: 'URL|TARGET_DIRECTORY|VERIFICATION_FUNCTION|VERIFICATION_FUNCTION_ARGUMENTS'
# VERIFICATION_FUNCTION will be called with arguments <downloaded file> <VERIFICATION_FUNCTION_ARGUMENTS>
images=(
	# Arch: https://mirrors.kernel.org/archlinux/iso/ (bootstrap image)
	"https://mirrors.kernel.org/archlinux/iso/${archVersion}/archlinux-bootstrap-${archVersion}-x86_64.tar.gz|${scratchDir}|verify::gpg_detached|https://mirrors.kernel.org/archlinux/iso/${archVersion}/archlinux-bootstrap-${archVersion}-x86_64.tar.gz.sig|${resDir}/archlinux-key.pgp"
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
	if gpg --quiet --homedir "$gpgScratchDirHome" --trust-model always --verify "$gpgScratchDir/signature.sig" "$1" &> /dev/null; then
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

ifInitial() {
	if [ "$reprovision" == 'false' ]; then
		"$@"
	fi
}
ifInitial msg 'Creating new partitions...'
# Typecode EF02 is from https://www.gnu.org/software/grub/manual/html_node/BIOS-installation.html
ifInitial sudo sgdisk --clear             \
	--new=1:1M:2M   --typecode=1:EF02 \
	--new=2:4M:8G   --typecode=2:EF00 \
	--new=3:9G:60G  --typecode=3:8300 \
	--largest-new=4 --typecode=4:8300 \
	--hybrid=1,2,3                    \
	--attributes=1:set:2              \
	"$device" 2>/dev/null
ifInitial refreshPartitions
ifInitial msg 'Creating filesystems...'
ifInitial sudo mkfs.vfat -i "$bootDOSID" "$bootDOSPartition" &>/dev/null
ifInitial sudo mkfs.vfat -i "$bootEFIID" "$bootEFIPartition" &>/dev/null
ifInitial refreshPartitions
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
cleanup::unmountEFI() {
	sudo umount -l "$bootEFIMountpoint" 2>/dev/null || true
}
cleanupTasks+=(cleanup::unmountEFI)

msg 'Preparing boot partitions...'
sudo mount "$bootEFIDevice" "$bootEFIMountpoint"
bootDirectory="$bootEFIMountpoint/boot"
efiISODirectory="$bootEFIMountpoint/isos"
efiBinDirectory="$bootEFIMountpoint/bin"
sudo mkdir -p "$bootDirectory" "$efiISODirectory" "$efiBinDirectory"
sudo chown root:root "$bootDirectory" "$efiISODirectory" "$efiBinDirectory"
ifInitial msg 'Installing GRUB for EFI...'
ifInitial sudo grub-install --target=x86_64-efi --efi-directory="$bootEFIMountpoint" --boot-directory="$bootDirectory" --removable --recheck
ifInitial msg 'Installing GRUB for legacy booting...'
ifInitial sudo grub-install --target=i386-pc --recheck --boot-directory="$bootDirectory" --removable "$device"
ifInitial refreshPartitions
if [ "$(cat /proc/sys/vm/dirty_background_bytes)" -eq 0 ]; then
	# This can slow the system down a lot by dirtying pages, so apply saner values.
	# See https://lwn.net/Articles/572911/
	sudo bash -c 'echo $((16*1024*1024)) > /proc/sys/vm/dirty_background_bytes'
	sudo bash -c 'echo $((48*1024*1024)) > /proc/sys/vm/dirty_bytes'
fi
msg 'Copying live Linux images...'
sudo ionice -c 3 -t cp -r "$scriptDir/boot"/* "$bootDirectory/"
for sourceISOFile in "$imagesDir"/*.iso; do
	targetISOFile="$efiISODirectory/$(basename "$sourceISOFile")"
	if [ -f "$targetISOFile" ]; then
		if [ "$skipImageVerification" == 'true' ]; then
			msg "Existing ISO '$(basename "$sourceISOFile")' detected, but image verification is off; assuming image is correct."
		else
			msg "Existing ISO '$(basename "$sourceISOFile")' detected, syncing..."
			sudo ionice -c 3 -t rsync -cth --inplace --progress "$sourceISOFile" "$targetISOFile"
		fi
	else
		sudo ionice -c 3 -t rsync -th --inplace --progress --bwlimit=16M "$sourceISOFile" "$targetISOFile"
	fi
done
sudo chown -R root:root "$efiISODirectory" "$efiBinDirectory"
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
ifInitial luksFormat "$archLUKSUUID" "$archPartition"
ifInitial luksFormat "$homeLUKSUUID" "$homePartition"
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
cleanup::closeLUKS || true # Try cleanup from previous runs.
cleanupTasks+=(cleanup::closeLUKS)
sudo cryptsetup open --key-file="$tempLUKSKeyFile1" "$archPartition" travos-arch
sudo cryptsetup open --key-file="$tempLUKSKeyFile1" "$homePartition" travos-home
archMappedPartition='/dev/mapper/travos-arch'
homeMappedPartition='/dev/mapper/travos-home'
ifInitial sudo mkfs.ext4 -qFU "$archRealUUID" -O '^has_journal'      "$archMappedPartition" 2>/dev/null
ifInitial sudo mkfs.ext4 -qFU "$homeRealUUID" -O '^has_journal' -m 0 "$homeMappedPartition" 2>/dev/null
ifInitial refreshPartitions
cleanup::unmountArchPartitions() {
	sudo umount -l "$archMappedPartition" "$archMountpoint" 2>/dev/null || true
	sudo umount -l "$homeMappedPartition" "$homeMountpoint" 2>/dev/null || true
}
cleanupTasks+=(cleanup::unmountArchPartitions)
sudo mount "$archMappedPartition" "$archMountpoint"
sudo mount "$homeMappedPartition" "$homeMountpoint"
archBootstrapImage="$scratchDir/archlinux-bootstrap-${archVersion}-x86_64.tar.gz"
ifInitial sudo ionice -c 3 -t bsdtar xzf "$archBootstrapImage" --same-owner --numeric-owner --xattrs --strip-components=1 -C "$archMountpoint/"

# Bootstrap Arch.
archChroot() {
	if ! sudo "$archMountpoint/bin/arch-chroot" "$archMountpoint" "$@"; then
		msg "Command failed inside chroot: $@"
		cleanup 1
	fi
}
bootEFIMountpointWithinArch="$archMountpoint/boot-efi"
travosDirWithinArch="$archMountpoint/travos"
qemuEthernetMACAddress='00:75:a1:05:9e:80'
qemuEthernetInterface='qemu0'
sudo mkdir -p "$bootEFIMountpointWithinArch" "$archMountpoint/boot" "$travosDirWithinArch"
sudo chmod 700 "$bootEFIMountpointWithinArch" "$archMountpoint/boot" "$travosDirWithinArch"
sudo touch "$travosDirWithinArch/luks.key"
sudo chmod 400 "$travosDirWithinArch/luks.key"
cat "$tempLUKSKeyFile1" | sudo tee "$travosDirWithinArch/luks.key" > /dev/null
cat "$PROVISIONING_PUBLIC_KEY" | sudo tee "$travosDirWithinArch/ssh_authorized_keys" > /dev/null
sudo chmod 600 "$travosDirWithinArch/ssh_authorized_keys"
cleanup::unmountArchBootPartitions() {
	sudo umount -l "$archMountpoint/boot" 2>/dev/null || true
	sudo umount -l "$bootEFIMountpointWithinArch" 2>/dev/null || true
}
cleanupTasks+=(cleanup::unmountArchBootPartitions)
sudo mount "$bootEFIDevice" "$bootEFIMountpointWithinArch"
sudo mount --bind "$bootEFIMountpointWithinArch/boot" "$archMountpoint/boot"
if [ "$reprovision" == 'false' ]; then
	echo 'Server = http://mirrors.kernel.org/archlinux/$repo/os/$arch' | sudo tee "$archMountpoint/etc/pacman.d/mirrorlist" > /dev/null
	echo 'LANG=en_US.UTF-8' | sudo tee "$archMountpoint/etc/locale.conf" > /dev/null
	echo 'en_US.UTF-8 UTF-8' | sudo tee "$archMountpoint/etc/locale.gen" > /dev/null
	echo 'KEYMAP=us' | sudo tee "$archMountpoint/etc/vconsole.conf" > /dev/null
	msg 'Preparing pacman...'
	archChroot pacman-key --init &> /dev/null
	archChroot pacman-key --populate archlinux &> /dev/null
	msg 'Performing initial system upgrade...'
	tryAFewTimes archChroot pacman --quiet --noconfirm --sync --refresh --refresh --sysupgrade
	msg 'Installing base packages...'
	tryAFewTimes archChroot pacman --quiet --noconfirm --sync --refresh --needed base linux grub arch-install-scripts mkinitcpio netctl ifplugd openssh haveged python python2
	msg 'Generating locales...'
	archChroot locale-gen &> /dev/null
	if ! grep -qP '^HOOKS="base udev autodetect modconf block filesystems keyboard fsck"$' "$archMountpoint/etc/mkinitcpio.conf"; then
		msg "Default HOOKS have changed in the Arch bootstrai image's mkinitcpio.conf." >&2
		msg "Current HOOKS: $(grep -P '^HOOKS=' "$archMountpoint/etc/mkinitcpio.conf")" >&2
		msg 'Please update this script with the new hooks.' >&2
		cleanup 1
	fi
	sudo sed -ri 's/^MODULES="(.*)"/MODULES="\1 ohci_pci xhci-hcd"/g' "$archMountpoint/etc/mkinitcpio.conf"
	# It's important to put the 'keyboard' hook before the 'autodetect' hook, otherwise not
	# all keyboards will get recognized at boot.
	sudo sed -ri 's/^HOOKS=.*$/HOOKS="base systemd keyboard autodetect sd-vconsole modconf block sd-encrypt filesystems fsck"/' "$archMountpoint/etc/mkinitcpio.conf"
	msg 'Generating initramfs...'
	archChroot mkinitcpio -p linux
	echo travos | sudo tee "$archMountpoint/etc/hostname" > /dev/null
	echo 'SUBSYSTEM=="net",'                              \
		'ACTION=="add",'                              \
		"ATTR{address}==\"$qemuEthernetMACAddress\"," \
		"NAME=\"$qemuEthernetInterface\""             \
		| sudo tee "$archMountpoint/etc/udev/rules.d/10-qemu-ethernet.rules" > /dev/null

	echo "Description='QEMU ethernet connection for TravOS setup'" >  "$tempDir/travos-qemu"
	echo 'Interface=qemu0'                                         >> "$tempDir/travos-qemu"
	echo 'Connection=ethernet'                                     >> "$tempDir/travos-qemu"
	echo 'IP=dhcp'                                                 >> "$tempDir/travos-qemu"

	echo '# <file system>  <dir>    <type> <options>     <dump> <pass>'     >  "$tempDir/fstab"
	echo "/dev/mapper/root /         ext4  defaults,noatime,discard 0 1"    >> "$tempDir/fstab"
	echo "/dev/mapper/home /home     ext4  defaults,noatime,discard 0 2"    >> "$tempDir/fstab"
	echo "UUID=$bootEFIUUID   /boot-efi vfat  defaults                 0 2" >> "$tempDir/fstab"
	echo "/boot-efi/boot   /boot     none  bind                     0 0"    >> "$tempDir/fstab"
	echo 'tmpfs            /tmp      tmpfs nodev,nosuid             0 0'    >> "$tempDir/fstab"

	echo '# <name> <underlying device> <keyfile> <cryptsetup options>'             >  "$tempDir/crypttab"
	echo "home UUID=$homeLUKSUUID /travos/luks.key luks,timeout=30,allow-discards" >> "$tempDir/crypttab"

	cat "$tempDir/travos-qemu"       | sudo tee "$archMountpoint/etc/netctl/travos-qemu" > /dev/null
	cat "$tempDir/fstab"             | sudo tee "$archMountpoint/etc/fstab"              > /dev/null
	cat "$tempDir/crypttab"          | sudo tee "$archMountpoint/etc/crypttab"           > /dev/null
	sudo chmod 644 "$archMountpoint/etc/fstab"
	sudo chmod 600 "$archMountpoint/etc/crypttab"
fi

msg 'Preparing Arch installation for provisioning...'
archChroot systemctl enable "netctl-ifplugd@$qemuEthernetInterface"
sudo cp "$resDir/travos-ssh-bootstrap.service" "$archMountpoint/etc/systemd/system/"
sudo chmod 644 "$archMountpoint/etc/systemd/system/travos-ssh-bootstrap.service"
sudo ln -fs '/etc/systemd/system/travos-ssh-bootstrap.service' "$archMountpoint/etc/systemd/system/multi-user.target.wants/"

# Unmount Arch partitions before we start up a VM against them.
msg 'Committing disk changes...'
sudo sync
cleanup::unmountArchBootPartitions || true
cleanup::unmountArchPartitions || true
sudo sync

msg 'Launching Arch in background QEMU...'
touch "$tempDir/qemu.pid"
cat <<EOF > "$tempDir/qemu-launch.sh"
#!/usr/bin/env bash

set -u
set +x
qemu-system-x86_64                                                 \
	-enable-kvm                                                \
	-localtime                                                 \
	-m 4G                                                      \
	-vga std -nographic                                        \
	-device e1000,netdev=mynet0,mac="$qemuEthernetMACAddress"  \
	-netdev user,id=mynet0,hostfwd=tcp::2244-:2244             \
	-drive file="$device",cache=none,format=raw                \
	-drive file="$archMappedPartition",cache=none,format=raw   \
	-kernel "$bootDirectory/vmlinuz-linux"                     \
	-initrd "$bootDirectory/initramfs-linux.img"               \
	-append root="/dev/disk/by-uuid/$archRealUUID" &
echo "\$!" > "$tempDir/qemu.pid"
sync
wait
EOF
chmod +x "$tempDir/qemu-launch.sh"
sudo "$tempDir/qemu-launch.sh" 2>/dev/null &
archQEMUPID=''
for i in $(seq 1 10); do
	sleep 1
	if [ "$(cat "$tempDir/qemu.pid" | wc -l)" -gt 0 ]; then
		archQEMUPID="$(cat "$tempDir/qemu.pid")"
		break
	fi
done
if [ -z "$archQEMUPID" ]; then
	msg 'Failed to start Arch in background QEMU.'
	cleanup 1
fi
qemu::forceKillArch() {
	sudo kill -9 "$archQEMUPID"
}
cleanupTasks+=(qemu::forceKillArch)
qemu::killAndWaitArch() {
	sudo kill "$archQEMUPID" || true
	wait "$archQEMUPID"
}
qemuSSHArgs=(-i "$PROVISIONING_PRIVATE_KEY" -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no)
qemu::waitForSSH() {
	msg 'Waiting for Arch to come up...'
	sleep 10
	archConnected='false'
	for i in $(seq 1 10); do
		if ssh -p 2244 "${qemuSSHArgs[@]}" root@localhost uptime &> /dev/null; then
			msg 'Connected to Arch.'
			archConnected='true'
			break
		fi
		msg "Still waiting for Arch to come up... ($i/10)"
		sleep 5
	done
	if [ "$archConnected" == 'false' ]; then
		msg 'Arch did not come up in time.'
		cleanup 1
	fi
}
cat <<EOF > "$tempDir/ansible.cfg"
[defaults]
inventory = ansible-inventory.ini
roles_path = $ansibleRolesPath

[ssh_connection]
ssh_args = ${qemuSSHArgs[@]}
EOF
cat <<EOF > "$tempDir/ansible-inventory.ini"
[all]
travos ansible_host=localhost ansible_user=root ansible_port=2244
EOF
cat <<EOF > "$tempDir/playbook.yml"
- hosts: [all]
  roles: [${ansibleRoles}]
EOF
qemu::waitForSSH
cleanup::sync() {
	sudo sync
}
cleanupTasks+=(cleanup::sync)
pushd "$tempDir" &> /dev/null
	tryAFewTimes ansible-playbook playbook.yml -l travos
popd &> /dev/null

sudo sync

qemu::launch() {
	sudo qemu-system-x86_64 -enable-kvm -localtime -m 4G -vga std -drive file="$device",cache=none,format=raw "$@" 2>&1 | (grep --line-buffered -vP '^$|Gtk-WARNING' || cat)
}

if [ "$isTest" == 'true' ]; then
	msg 'Launching QEMU...'
	qemu::launch
fi
msg 'All done.'
cleanup 0
