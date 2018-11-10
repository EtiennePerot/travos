#!/usr/bin/env bash

set -euo pipefail

# Replace stdin with /dev/null and store the real stdin in file descriptor 3.
exec 3<&0 </dev/null

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
	if [ "${#cleanupTasks[@]}" -gt 0 ]; then
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
	fi
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
waitPID() {
	while stat "/proc/$1" &> /dev/null; do
		sleep 1
	done
}

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
	"$@" || return 1
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
	echo '     --hostname=foo         Set the hostname to the given value. (Default: "travos".)' >&2
	echo '     --root-boundary=60G    Set the upper boundary of the root partition, with G suffix.' >&2
	echo '                            Note that the first 9G will be reserved for other' >&2
	echo '                            partitions. The 60G default means a root size of 51G.' >&2
	echo '     --debug                Print all commands as they run & misc debugging tweaks.'   >&2
	echo '     --reprovision          Update an existing key and re-run Ansible provisioning.'   >&2
	echo '     --reprovision-local    Re-run Ansible provisioning on the local running system.'   >&2
	echo '     --provision-loop       Prompt to re-run provisioning after every provisioning.'   >&2
	echo '     --skip-verification    If set, downloaded images are not verified for integrity.' >&2
	echo '     --test-unlocked        Implies --test; runs Arch on unlocked partitions.'         >&2
	echo '     --uuid-force           Run even if disks with colliding UUIDs are present.'       >&2
	echo '                            This may cause data loss.'                                 >&2
	echo '     --uuid-offset=0        Set UUID offset from 0 to 9. Can be used to deal with'     >&2
	echo '                            disk UUID collisions.'                                     >&2
	cleanup 1
}

device=''
isTest='false'
isTestUnlocked='false'
skipImageVerification='false'
reprovision='false'
reprovisionLocal='false'
provisionLoop='false'
isUUIDForce='false'
uuidOffset='0'
nextArgIsUUIDOffset='false'
configFile=''
nextArgIsConfigFile='false'
chosenHostname='travos'
nextArgIsHostname='false'
rootBoundary='60G'
nextArgIsRootBoundary='false'
for arg; do
	if [ "$nextArgIsConfigFile" == 'true' ]; then
		configFile="$arg"
		nextArgIsConfigFile='false'
	elif [ "$nextArgIsUUIDOffset" == 'true' ]; then
		uuidOffset="$arg"
		nextArgIsUUIDOffset='false'
	elif [ "$nextArgIsHostname" == 'true' ]; then
		chosenHostname="$arg"
		nextArgIsHostname='false'
	elif [ "$nextArgIsRootBoundary" == 'true' ]; then
		rootBoundary="$arg"
		nextArgIsRootBoundary='false'
	elif [ "$arg" == --test -o "$arg" == -test ]; then
		isTest='true'
	elif [ "$arg" == --test-unlocked -o "$arg" == -test-unlocked ]; then
		isTest='true'
		isTestUnlocked='true'
	elif [ "$arg" == --uuid-force -o "$arg" == -uuid-force ]; then
		isUUIDForce='true'
	elif [ "$arg" == --config -o "$arg" == -config ]; then
		nextArgIsConfigFile='true'
	elif echo "$arg" | grep -qiP '^--?config=.+$'; then
		configFile="$(echo "$arg" | cut -d'=' -f2-)"
	elif [ "$arg" == --uuid-offset -o "$arg" == -uuid-offset ]; then
		nextArgIsUUIDOffset='true'
	elif echo "$arg" | grep -qiP '^--?uuid-offset=.+$'; then
		uuidOffset="$(echo "$arg" | cut -d'=' -f2-)"
	elif [ "$arg" == --hostname -o "$arg" == -hostname ]; then
		nextArgIsHostname='true'
	elif echo "$arg" | grep -qiP '^--?hostname=.+$'; then
		chosenHostname="$(echo "$arg" | cut -d'=' -f2-)"
	elif echo "$arg" | grep -qiP '^--?root-boundary=.+$'; then
		rootBoundary="$(echo "$arg" | cut -d'=' -f2-)"
	elif [ "$arg" == --debug -o "$arg" == -debug ]; then
		isDebug='true'
		set -x
	elif [ "$arg" == --skip-verification -o "$arg" == -skip-verification ]; then
		skipImageVerification='true'
	elif [ "$arg" == --reprovision-local -o "$arg" == -reprovision-local ]; then
		reprovisionLocal='true'
	elif [ "$arg" == --reprovision -o "$arg" == -reprovision ]; then
		reprovision='true'
	elif [ "$arg" == --provision-loop -o "$arg" == -provision-loop ]; then
		provisionLoop='true'
	elif [ "$arg" == --help -o "$arg" == -help -o "$arg" == -h -o "$arg" == --usage -o "$arg" == -usage ]; then
		usage
	elif echo "$arg" | grep -qiP '^-'; then
		msg "Unrecognized flag: '$arg'"
		usage
	elif [ -n "$device" ]; then
		msg "May only specify one device flag (found '$device' and '$arg')."
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
if ! echo "$uuidOffset" | grep -qiP '^[0-9]$'; then
	msg "UUID offset must be a digit between 0 and 9 (got '$uuidOffset')."
	usage
fi
if ! echo "$rootBoundary" | grep -qP '^[0-9]+G'; then
	msg "Root boundary must be of the format 'xG' (with 'x' being the number of gigabytes)."
	usage
fi
if [ "$(echo "$rootBoundary" | cut -d'G' -f1)" -lt 21 ]; then
	msg "Root boundary is too small. The root system files won't fit in there."
	usage
fi
if [ "$reprovisionLocal" == 'true' ]; then
	if [ "$reprovision" == 'true' ]; then
		msg "Cannot specify with --reprovision and --reprovision-local."
		usage
	fi
	if [ -n "$device" ]; then
		msg "Cannot specify a device to install to with --reprovision-local."
		usage
	fi
	if [ "$isTest" == 'true' ]; then
		msg "Cannot run in test mode with --reprovision-local."
		usage
	fi
fi
if [ "$isTest" == 'true' -a -z "$device" ]; then
	testScratchImage="$scratchDir/test.img"
	if [ "$reprovision" != 'true' ]; then
		rm -f "$testScratchImage"
	fi
	if [ ! -f "$testScratchImage" ]; then
		truncate -s 128G "$testScratchImage"
	fi
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
if [ "$reprovisionLocal" != true ]; then
	if [ -z "$device" ]; then
		msg 'Must specify device as /dev/sdX'
		usage
	fi
	if [ ! -e "$device" ]; then
		msg "Device '$device' does not exist."
		usage
	fi
fi
refreshPartitions() {
	if [ -n "$device" ]; then
		sudo partprobe "$device"
	fi
	sudo partprobe || true
	sleep 3
	sudo partprobe || true
}
refreshPartitions || true

msg "Reading configuration '$configFile'..."
LUKS_PASSWORD=''
LUKS_KEYFILE=''
PROVISIONING_PRIVATE_KEY=''
PROVISIONING_PUBLIC_KEY=''
ANSIBLE_ROLES_PATH=()
ANSIBLE_ROLES=()
ANSIBLE_LIBRARY=()
ANSIBLE_ACTION_PLUGINS=()
EXTRA_LINUX_BOOT_OPTIONS=''
source "$configFile"
if [ -z "$LUKS_PASSWORD" -a -z "$LUKS_KEYFILE" ]; then
	msg 'Config file must specify at least one of LUKS_PASSWORD, LUKS_KEYFILE.'
	cleanup 1
fi
if [ -n "$LUKS_KEYFILE" -a ! -f "$LUKS_KEYFILE" ]; then
	msg "LUKS_KEYFILE '$LUKS_KEYFILE' does not exist or is not a file."
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
for ansibleRolePath in "${ANSIBLE_ROLES_PATH[@]}"; do
	if [ ! -d "$ansibleRolePath" ]; then
		msg "Ansible role path '$ansibleRolePath' does not exist or is not a directory."
		cleanup 1
	fi
	ansibleRolesPath="${ansibleRolesPath}:${ansibleRolePath}"
done
ansibleRoles='travos'
for ansibleRole in "${ANSIBLE_ROLES[@]}"; do
	ansibleRoles="${ansibleRoles}, $ansibleRole"
done
ansibleLibrary="$scriptDir/ansible/library"
for ansibleLibraryPath in "${ANSIBLE_LIBRARY[@]}"; do
	if [ ! -d "$ansibleLibraryPath" ]; then
		msg "Ansible library path '$ansibleLibraryPath' does not exist or is not a directory."
		cleanup 1
	fi
	ansibleLibrary="${ansibleLibrary}:${ansibleLibraryPath}"
done
ansibleActionPlugins=''
for ansibleActionPluginsPath in "${ANSIBLE_ACTION_PLUGINS[@]}"; do
	if [ ! -d "$ansibleActionPluginsPath" ]; then
		msg "Ansible action plugins path '$ansibleActionPluginsPath' does not exist or is not a directory."
		cleanup 1
	fi
	if [ "$ansibleActionPlugins" == '' ]; then
		ansibleActionPlugins="$ansibleActionPluginsPath"
	else
		ansibleActionPlugins="${ansibleActionPlugins}:${ansibleActionPluginsPath}"
	fi
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
archVersion='2018.10.01'
kaliVersion='2018.3a'
tailsVersion='3.10.1'
systemRescueCDVersion='5.3.1'
# Syntax: 'URL|TARGET_DIRECTORY|VERIFICATION_FUNCTION|VERIFICATION_FUNCTION_ARGUMENTS'
# VERIFICATION_FUNCTION will be called with arguments <downloaded file> <VERIFICATION_FUNCTION_ARGUMENTS>
images=(
	# Arch: https://mirrors.kernel.org/archlinux/iso/ (bootstrap image)
	"https://mirrors.kernel.org/archlinux/iso/${archVersion}/archlinux-bootstrap-${archVersion}-x86_64.tar.gz|${scratchDir}|verify::gpg_detached|https://mirrors.kernel.org/archlinux/iso/${archVersion}/archlinux-bootstrap-${archVersion}-x86_64.tar.gz.sig|${resDir}/archlinux-key.pgp"
	# Kali Linux: https://www.kali.org/downloads/
	"http://cdimage.kali.org/kali-${kaliVersion}/kali-linux-kde-${kaliVersion}-amd64.iso|${imagesDir}|verify::sha256|7fad2a1058f881d6ed37f5da05c4bab95852abfdb526ea86346e21eb7c7ac629"
	# Tails: https://tails.boum.org/install/download/index.en.html
	"https://mirrors.wikimedia.org/tails/stable/tails-amd64-${tailsVersion}/tails-amd64-${tailsVersion}.iso|${imagesDir}|verify::gpg_detached|https://tails.boum.org/torrents/files/tails-amd64-${tailsVersion}.iso.sig|https://tails.boum.org/tails-signing.key"
	# System Rescue CD: http://www.system-rescue-cd.org/Download/
	"https://downloads.sourceforge.net/project/systemrescuecd/sysresccd-x86/${systemRescueCDVersion}/systemrescuecd-x86-${systemRescueCDVersion}.iso|${imagesDir}|verify::sha256|ee4d1f2b9c15350cac6a098366809ba0b6573fa5d3c28874ad5ca28559f4a32d"
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

offsetUUID() {
	echo "$1" | sed -r "s/o/${uuidOffset}/g"
}

# Partition 1: MSDOS boot, 32M,  fat32,     ID B007-oD05 "boot dos"
# Partition 2: EFI boot,   ~8G,  fat32,     ID B007-oEF1 "boot efi"
# Partition 3: Arch,       48GB, LUKS+ext4, UUID 0075a105-1035-a5c8-oooo-deadbeefcafe "arch"
# Partition 4: Home,       rest, LUKS+ext4, UUID 0075a105-1035-803e-oooo-deadbeefcafe "home"
# "o" is replaced by the UUID offset (default "0").
bootDOSID="$(offsetUUID    'B007oD05')"   # As specified to mkfs.fat32.
bootDOSUUID="$(offsetUUID  'B007-oD05')"  # As listed in /dev/disk/by-uuid.
bootEFIID="$(offsetUUID    'B007oEF1')"   # As specified to mkfs.fat32.
bootEFIUUID="$(offsetUUID  'B007-oEF1')"  # As listed in /dev/disk/by-uuid.
archLUKSUUID="$(offsetUUID '0075a105-1035-a5c8-oooo-deadbeefcafe')"
archRealUUID="$(offsetUUID '0075a105-5ea1-a5c8-oooo-deadbeefcafe')"
homeLUKSUUID="$(offsetUUID '0075a105-1035-803e-oooo-deadbeefcafe')"
homeRealUUID="$(offsetUUID '0075a105-5ea1-803e-oooo-deadbeefcafe')"

uuidDeviceExists() {
	test -e "/dev/disk/by-uuid/$1"
}

anyUUIDExists() {
	if uuidDeviceExists "$bootDOSUUID"; then
		echo "$bootDOSUUID"
		return 0
	fi
	if uuidDeviceExists "$bootEFIUUID"; then
		echo "$bootEFIUUID"
		return 0
	fi
	if uuidDeviceExists "$archLUKSUUID"; then
		echo "$archLUKSUUID"
		return 0
	fi
	if uuidDeviceExists "$archRealUUID"; then
		echo "$archRealUUID"
		return 0
	fi
	if uuidDeviceExists "$homeLUKSUUID"; then
		echo "$homeLUKSUUID"
		return 0
	fi
	if uuidDeviceExists "$homeRealUUID"; then
		echo "$homeRealUUID"
		return 0
	fi
	return 1
}

if anyUUIDExists &> /dev/null; then
	msg "Device with UUID '$(anyUUIDExists || true)' already exists."
	if [ "$reprovision" == 'true' -o "$reprovisionLocal" == 'true' ]; then
		msg '... but we are reprovisioning this device, so this is to be expected.'
	elif [ "$isUUIDForce" == 'true' ]; then
		msg 'Because --uuid-force was set, the script will continue anyway.'
		msg 'THIS MAY CAUSE DATA LOSS.'
		msg 'You have 15 seconds to press Ctrl+C to kill this script.'
		sleep 18 # 3 extra seconds!
	else
		msg 'This may be because a run of this script did not complete properly,'
		msg 'or because you are running this script on a system that was set up by'
		msg 'this very same script. Re-running it may cause data loss.'
		msg 'Please use --uuid-force or change --uuid-offset to continue.'
		cleanup 1
	fi
fi

ifInitial() {
	if [ "$reprovision" == 'false' -a "$reprovisionLocal" == 'false' ]; then
		"$@"
	fi
}
if [ "$reprovisionLocal" == 'false' ]; then
	ifInitial msg 'Creating new partitions...'
	ifInitial sudo sgdisk --zap-all "$device" 2> /dev/null
	# Typecode EF02 is from https://www.gnu.org/software/grub/manual/html_node/BIOS-installation.html
	ifInitial sudo sgdisk --clear                        \
		--new='1:1M:2M'            --typecode=1:EF02 \
		--new='2:4M:8G'            --typecode=2:EF00 \
		--new="3:9G:$rootBoundary" --typecode=3:8300 \
		--largest-new='4'          --typecode=4:8300 \
		--hybrid='1,2,3'                             \
		--attributes='1:set:2'                       \
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
	sudo ionice -c 3 -t rsync -rth --inplace --progress --bwlimit=16M "$scriptDir/boot"/* "$bootDirectory/"
	cat "$scriptDir/boot/grub/grub.cfg" | sed -r "s/%UUID_OFFSET%/${uuidOffset}/g" | sed -r "s~%EXTRA_LINUX_BOOT_OPTIONS%~${EXTRA_LINUX_BOOT_OPTIONS}~g" | sudo tee "$bootDirectory/grub/grub.cfg" > /dev/null
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
		cat <<EOF | tr -d '\n' > "$tempLUKSKeyFile1"
$LUKS_PASSWORD
EOF
	else
		cat "$LUKS_KEYFILE" > "$tempLUKSKeyFile1"
	fi
	luksFormat() {
		# Usage: luksFormat <UUID> <device>
		sudo cryptsetup luksFormat --batch-mode --key-file="$tempLUKSKeyFile1" --use-random --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 1000 --uuid="$1" "$2"
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
	if [ "$reprovision" == 'true' ]; then
		sudo fsck.ext4 -y "$archMappedPartition"
		sudo fsck.ext4 -y "$homeMappedPartition"
		refreshPartitions
	fi
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
	sudo chmod 711 "$bootEFIMountpointWithinArch" "$archMountpoint/boot" "$travosDirWithinArch"
	sudo touch "$travosDirWithinArch/luks.key"
	sudo chmod 400 "$travosDirWithinArch/luks.key"
	cat "$tempLUKSKeyFile1" | sudo tee "$travosDirWithinArch/luks.key" > /dev/null
	cat "$PROVISIONING_PUBLIC_KEY" | sudo tee "$travosDirWithinArch/ssh_authorized_keys" > /dev/null
	sudo chmod 644 "$travosDirWithinArch/ssh_authorized_keys"
	cleanup::unmountArchBootPartitions() {
		sudo umount -l "$archMountpoint/boot" 2>/dev/null || true
		sudo umount -l "$bootEFIMountpointWithinArch" 2>/dev/null || true
	}
	cleanupTasks+=(cleanup::unmountArchBootPartitions)
	sudo mount "$bootEFIDevice" "$bootEFIMountpointWithinArch"
	sudo mount --bind "$bootEFIMountpointWithinArch/boot" "$archMountpoint/boot"
fi
travosProvisioningUser='travos-prov'
if [ "$reprovision" == 'false' -a "$reprovisionLocal" == 'false' ]; then
	echo 'Server = http://mirrors.kernel.org/archlinux/$repo/os/$arch' | sudo tee "$archMountpoint/etc/pacman.d/mirrorlist" > /dev/null
	echo 'LANG=en_US.UTF-8' | sudo tee "$archMountpoint/etc/locale.conf" > /dev/null
	echo 'en_US.UTF-8 UTF-8' | sudo tee "$archMountpoint/etc/locale.gen" > /dev/null
	echo 'KEYMAP=us' | sudo tee "$archMountpoint/etc/vconsole.conf" > /dev/null
	msg 'Preparing pacman...'
	archChroot pacman-key --init &> /dev/null
	archChroot pacman-key --populate archlinux &> /dev/null
	# Delete Linux kernel if already built; we will regenerate it later anyway.
	# This avoids the "/boot/vmlinuz-linux exists in filesystem" that might show up when
	# doing an initial system upgrade from a bootstrap image that includes an older kernel
	# than the newest one.
	sudo rm -f "$archMountpoint/boot/vmlinuz-linux"
	msg 'Performing initial system upgrade...'
	tryAFewTimes archChroot pacman --quiet --noconfirm --sync --refresh --refresh --sysupgrade
	msg 'Installing base packages...'
	tryAFewTimes archChroot pacman --quiet --noconfirm --sync --refresh --needed base base-devel linux grub arch-install-scripts mkinitcpio netctl ifplugd openssh haveged python python2 sudo
	sudo mkdir -p "$travosDirWithinArch/bootstrap_pkg"
	sudo cp -r "$resDir/bootstrap_pkg"/*.tar.* "$travosDirWithinArch/bootstrap_pkg"
	tryAFewTimes archChroot pacman --quiet --noconfirm --sync --refresh --needed --asdeps $(sudo cat "$resDir/bootstrap_pkg/dependencies.packages")
	archChroot bash -c 'pacman --noconfirm --upgrade --needed /travos/bootstrap_pkg/*.tar.*'
	msg 'Generating locales...'
	archChroot locale-gen &> /dev/null
	msg 'Preparing provisioning user...'
	archChroot useradd -r -d /tmp -s /bin/bash "$travosProvisioningUser"
	echo "$travosProvisioningUser ALL=(ALL) NOPASSWD: /usr/bin/pacman" | sudo tee "$archMountpoint/etc/sudoers.d/allow-travos-provisioning" > /dev/null
	sudo chmod 440 "$archMountpoint/etc/sudoers.d/allow-travos-provisioning"
	msg 'Generating initramfs...'
	if ! grep -qP "^HOOKS=\\(base udev autodetect modconf block filesystems keyboard fsck\\)\$" "$archMountpoint/etc/mkinitcpio.conf"; then
		msg "Default HOOKS have changed in the Arch bootstrap image's mkinitcpio.conf." >&2
		msg "Current HOOKS: $(grep -P '^HOOKS=' "$archMountpoint/etc/mkinitcpio.conf")" >&2
		msg 'Please update this script with the new hooks.' >&2
		cleanup 1
	fi
	sudo sed -ri 's/^MODULES="(.*)"/MODULES="\1 xhci-pci xhci-hcd"/g' "$archMountpoint/etc/mkinitcpio.conf"
	# It's important to put the 'keyboard' hook before the 'autodetect' hook, otherwise not
	# all keyboards will get recognized at boot.
	sudo sed -ri 's/^HOOKS=.*$/HOOKS=(base systemd keyboard autodetect sd-vconsole modconf block sd-encrypt filesystems fsck)/' "$archMountpoint/etc/mkinitcpio.conf"
	archChroot mkinitcpio -p linux
	echo "$chosenHostname" | sudo tee "$archMountpoint/etc/hostname" > /dev/null
	echo 'SUBSYSTEM=="net",'                          \
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
provisioningSSHArgs=(-i "$PROVISIONING_PRIVATE_KEY" -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no)
waitForSSH() {
	msg 'Waiting for Arch to come up...'
	if [ "$reprovisionLocal" == 'true' ]; then
		sleep 1
	else
		sleep 10
	fi
	archConnected='false'
	for i in $(seq 1 10); do
		if ssh -p 2244 "${provisioningSSHArgs[@]}" "${travosProvisioningUser}@localhost" uptime &> /dev/null; then
			msg 'Connected to Arch.'
			archConnected='true'
			break
		fi
		msg "Still waiting for Arch to come up... ($i/10)"
		sleep 5
	done
	if [ "$archConnected" == 'false' ]; then
		msg 'Arch did not come up in time.'
		return 1
	fi
	return 0
}
if [ "$reprovisionLocal" == 'false' ]; then
	archChroot systemctl enable "netctl-ifplugd@$qemuEthernetInterface"
	sudo cp "$resDir/travos-ssh-bootstrap.service" "$archMountpoint/etc/systemd/system/"
	sudo chmod 644 "$archMountpoint/etc/systemd/system/travos-ssh-bootstrap.service"
	sudo rm -f "$archMountpoint/var/lib/pacman/db.lck"
	cleanup::disableBootstrapService() {
		archPartitionRemountedForBootstrap='false'
		if [ ! -f "$archMountpoint/etc/systemd/system/multi-user.target.wants/travos-ssh-bootstrap.service" ]; then
			sudo mount "$archMappedPartition" "$archMountpoint"
			archPartitionRemountedForBootstrap='true'
		fi
		sudo rm -f "$archMountpoint/etc/systemd/system/multi-user.target.wants/travos-ssh-bootstrap.service" &> /dev/null
		if [ "$archPartitionRemountedForBootstrap" == true ]; then
			sudo umount -l "$archMountpoint"
		fi
	}
	cleanupTasks+=(cleanup::disableBootstrapService)
	sudo ln -fs '/etc/systemd/system/travos-ssh-bootstrap.service' "$archMountpoint/etc/systemd/system/multi-user.target.wants/"

	# Unmount Arch partitions before we start up a VM against them.
	msg 'Committing disk changes...'
	sudo sync
	cleanup::unmountArchBootPartitions || true
	cleanup::unmountArchPartitions || true
	sudo sync

	archQEMUCommand=(
		qemu-system-x86_64                                             \
			-enable-kvm                                                \
			-m 4G                                                      \
			-vga std                                                   \
			-device e1000,netdev=mynet0,mac="$qemuEthernetMACAddress"  \
			-netdev user,id=mynet0,hostfwd=tcp::2244-:2244             \
			-drive file="$device",cache=none,format=raw                \
			-drive file="$archMappedPartition",cache=none,format=raw   \
			-kernel "$bootDirectory/vmlinuz-linux"                     \
			-initrd "$bootDirectory/initramfs-linux-fallback.img"      \
			-append root="/dev/disk/by-uuid/$archRealUUID"
	)
	if [ "$isDebug" == 'true' ]; then
		msg 'Launching Arch in QEMU...'
		graphicOptions=''
	else
		msg 'Launching Arch in background QEMU...'
		graphicOptions='-nographic'
	fi
	touch "$tempDir/qemu.pid"
	cat <<EOF > "$tempDir/qemu-launch.sh"
#!/usr/bin/env bash

set -u
set +x
${archQEMUCommand[@]} $graphicOptions &
echo "\$!" > "$tempDir/qemu.pid"
sync
wait
EOF
	chmod +x "$tempDir/qemu-launch.sh"
	sudo --background "$tempDir/qemu-launch.sh" &> /dev/null
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
		sudo kill -9 "$archQEMUPID" &> /dev/null || true
	}
	cleanupTasks+=(qemu::forceKillArch)
	qemu::killAndWaitArch() {
		sudo kill "$archQEMUPID" &> /dev/null || true
		waitPID "$archQEMUPID"
	}
	qemu::sync() {
		ssh -p 2244 "${provisioningSSHArgs[@]}" "root@localhost" sync &> /dev/null
	}
	qemu::shutdown() {
		qemu::sync
		for i in $(seq 1 5); do
			ssh -p 2244 "${provisioningSSHArgs[@]}" "root@localhost" poweroff &> /dev/null || true
		done
		sleep 3
		qemuTurnedOff='false'
		for i in $(seq 1 10); do
			if ! ssh -p 2244 "${provisioningSSHArgs[@]}" "root@localhost" uptime &> /dev/null; then
				qemuTurnedOff='true'
				break
			fi
			sleep 3
		done
		if [ "$qemuTurnedOff" == 'false' ]; then
			return 1
		fi
		waitPID "$archQEMUPID" || true
		sleep 1
		return 0
	}
	if ! waitForSSH; then
		if [ "$isDebug" == 'true' ]; then
			qemu::killAndWaitArch || true
			msg 'Spawning Arch again with visible display (for debugging)...'
			sudo "${archQEMUCommand[@]}" || true
		fi
		cleanup 1
	fi
else
	sudo cp "$resDir/travos-ssh-bootstrap.service" /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl start travos-ssh-bootstrap.service
	if ! waitForSSH; then
		msg 'Cannot connect to local SSH bootstrap service.'
		cleanup 1
	fi
fi

cat <<EOF > "$tempDir/ansible.cfg"
[defaults]
inventory = ansible-inventory.ini
library = $ansibleLibrary
roles_path = $ansibleRolesPath
action_plugins = $ansibleActionPlugins

[ssh_connection]
ssh_args = ${provisioningSSHArgs[@]}
EOF
cat <<EOF > "$tempDir/ansible-inventory.ini"
[all]
$chosenHostname ansible_host=localhost ansible_user=root ansible_port=2244
EOF
cat <<EOF > "$tempDir/playbook.yml"
- hosts: [all]
  roles: [${ansibleRoles}]
EOF
cleanup::sync() {
	sudo sync
}
cleanupTasks+=(cleanup::sync)
ansibleFailed='false'
pushd "$tempDir" &> /dev/null
	ansibleRetry='true'
	while [ "$ansibleRetry" == true ]; do
		if ansible-playbook playbook.yml -l "$chosenHostname"; then
			ansibleFailed='false'
			ansiblePrompt="$provisionLoop"
		else
			ansibleFailed='true'
			ansiblePrompt='true'
		fi
		if [ "$ansiblePrompt" == true ]; then
			if [ "$ansibleFailed" == true ]; then
				echo -n '>> Ansible failed. Retry? (Y/n) '
			else
				echo -n '>> Ansible succeeded. Run it again? (Y/n) '
			fi
			read -r ansibleRetryPrompt <&3
			ansibleRetryPrompt="$(echo "$ansibleRetryPrompt" | tr '[:upper:]' '[:lower:]')"
			if [ "$ansibleRetryPrompt" == n -o "$ansibleRetryPrompt" == no ]; then
				ansibleRetry='false'
			else
				ansibleRetry='true'
			fi
		else
			ansibleRetry='false'
		fi
	done
popd &> /dev/null

if [ "$reprovisionLocal" == 'false' ]; then
	msg 'Stopping Arch VM...'
	cleanup::disableBootstrapService
	qemu::sync
	sudo sync
	qemu::shutdown

	if [ "$isTest" == 'true' ]; then
		if [ "$isTestUnlocked" == true ]; then
			msg 'Launching QEMU... (unlocked)'
			sudo "${archQEMUCommand[@]}" 2>&1 | (grep --line-buffered -vP '^$|Gtk-WARNING' || cat)
		else
			msg 'Launching QEMU...'
			sudo qemu-system-x86_64                                       \
				-enable-kvm                                               \
				-m 4G                                                     \
				-vga std                                                  \
				-device e1000,netdev=mynet0,mac="$qemuEthernetMACAddress" \
				-netdev user,id=mynet0                                    \
				-drive file="$device",cache=none,format=raw               \
				2>&1 | (grep --line-buffered -vP '^$|Gtk-WARNING' || cat)
		fi
	fi
fi

if [ "$ansibleFailed" == true ]; then
	msg 'All done, though there were errors running Ansible.'
	cleanup 4
else
	msg 'All done.'
	cleanup 0
fi
