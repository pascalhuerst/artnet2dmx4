#!/bin/bash

MOUNT_POINT_ROOT=/tmp/root
MOUNT_POINT_BOOT=/tmp/boot
IMAGE_VERSION_INFO_FILE=${MOUNT_POINT_ROOT}/etc/nonlinear_release
DEVICE=""
DEVICE_P1=""
DEVICE_P2=""

# Parameters
OPT_WIFI_NAME=""
OPT_WIFI_PW=""
OPT_RELEASE_NOTE=""
OPT_RECREATE_PARTITIONS=false
OPT_COPY_ROOTFS=false
OPT_COPY_BOOTFS=false
OPT_CREATE_INSTALL_MEDIA=false
OPT_DEBUG=0

function is_mounted {
	if [ "$(cat /proc/mounts | grep $1)" = "" ]; then
		return 0
	else
		return 1
	fi
}

function write_release_file {
	printf "Updating build information in target fs...\n"
	printf "Nonlinear Labs Nonlinux Version:\n" > ${IMAGE_VERSION_INFO_FILE}
	printf "Nonlinux based on SHA1: $(git rev-parse HEAD)\n" >> ${IMAGE_VERSION_INFO_FILE}
	printf "Image Built: $(date)\n" >> ${IMAGE_VERSION_INFO_FILE}
	printf "Snapshot: $(git rev-parse --abbrev-ref HEAD)\n" >> ${IMAGE_VERSION_INFO_FILE}
	if [[ ! -z ${OPT_RELEASE_NOTE} ]]; then
		printf "Notes:\n %s\n" "${OPT_RELEASE_NOTE}" >> ${IMAGE_VERSION_INFO_FILE}
	fi
}

function write_uenv_file {
	printf "Creating uEnv.txt...\n"
	MMC_CMDS="uenvcmd=mmc rescan"
	MMC_CMDS="${MMC_CMDS}; setenv fdtaddr 0x88000000"
	MMC_CMDS="${MMC_CMDS}; load mmc 0:2 \${loadaddr} boot/uImage"
	MMC_CMDS="${MMC_CMDS}; load mmc 0:2 \${fdtaddr} boot/am335x-boneblack.dtb"
	MMC_CMDS="${MMC_CMDS}; setenv mmcroot /dev/mmcblk0p2 ro"
	MMC_CMDS="${MMC_CMDS}; setenv mmcrootfstype ext4 rootwait"
	MMC_CMDS="${MMC_CMDS}; setenv bootargs console=\${console} \${optargs} root=\${mmcroot} rootfstype=\${mmcrootfstype}"
	MMC_CMDS="${MMC_CMDS}; bootm \${loadaddr} - \${fdtaddr}"
	echo "${MMC_CMDS}" > ${MOUNT_POINT_BOOT}/uEnv.txt
}

function set_ssid {
	if [[ ! -z ${OPT_WIFI_NAME} ]]; then
		printf "Changing SSID to ${OPT_WIFI_NAME}...\n"
		sed -i -- "s/ssid=NonLinearInstrument/ssid=${OPT_WIFI_NAME}/g" ${MOUNT_POINT_ROOT}/etc/hostapd.conf
	fi
}

function set_password {
	if [[ ! -z ${OPT_WIFI_PW} ]]; then
		printf "Changing WLAN password to ${OPT_WIFI_PW}...\n"
		sed -i -- "s/wpa_passphrase=88888888/wpa_passphrase=${OPT_WIFI_PW}/g" ${MOUNT_POINT_ROOT}/etc/hostapd.conf
	fi
}

function mount_boot {
	printf "Mounting boot partition at ${MOUNT_POINT_BOOT}\n"
	mkdir -p ${MOUNT_POINT_BOOT}
	if ! mount ${DEVICE_P1} ${MOUNT_POINT_BOOT}; then
		printf "Can not mount ${DEVICE_P1}. Aborting...\n"
		exit -1
	fi
}

function mount_root {
	printf "Mounting root partition at ${MOUNT_POINT_ROOT}\n"
	mkdir -p ${MOUNT_POINT_ROOT}
	if ! mount ${DEVICE_P2} ${MOUNT_POINT_ROOT}; then
		printf "Can not mount ${DEVICE_P2}. Aborting...\n"
		exit -1
	fi
}

function unmount_boot {
	printf "Unmounting boot...\n"
	umount ${MOUNT_POINT_BOOT}
}

function unmount_root {
	printf "Unmounting rootfs...\n"
	umount ${MOUNT_POINT_ROOT}
}

function sync_rootfs {
	printf "Syncing rootfs...\n"
	if ! tar -C ${MOUNT_POINT_ROOT} -xf output/images/rootfs.tar; then
		printf "Can not untar rootfs.tar. Aborting...\n"
		exit -1
	fi
	sync
}

function sync_bootfs {
	printf "Syncing bootfs...\n"
	if ! cp -v output/images/u-boot.img ${MOUNT_POINT_BOOT}; then
		printf "Can not copy u-boot.img. Aborting...\n"
		exit -1
	fi
	if ! cp -v output/images/MLO ${MOUNT_POINT_BOOT}; then
		printf "Can not copy MLO. Aborting...\n"
	fi
}

function rewrite_partitions {
	printf "Flushing old partition table...\n"
	dd if=/dev/zero of=${DEVICE} bs=1024 count=1024 2>/dev/null 1>/dev/null && sync

	printf "Creating new partition table...\n"
	echo -e ',50M,c,*\n,\n' | sudo sfdisk ${DEVICE} 2>/dev/null 1>/dev/null && sync

	printf "Creating Partitions...\n"
	mkfs.vfat -n BOOT ${DEVICE_P1} 1>/dev/null 2>/dev/null
	mkfs.ext3 ${DEVICE_P2} 1>/dev/null 2>/dev/null

	printf "Rereading partition table...\n"
	partprobe ${DEVICE} && sync
}

function check_if_mounted_and_unmount {
	PARTITIONS=$(ls "$DEVICE"?* 2>/dev/null)
	if [ -n "$PARTITIONS" ]; then
		printf "Checking mountpoints:\n"
	fi

	for partition in $PARTITIONS; do
		is_mounted $partition
		if [ $? -eq 1 ]; then
			printf "  $partition: is mounted. Unmounting...\n"
			umount "$partition" 2>/dev/null
		else
			printf "  $partition: is not mounted. Ok...\n"
		fi
	done
	printf "\n"
}

function usage {
	printf "Usage:\n\n"
	printf "$0 [options] <PATH TO CARD>\n\n";
	printf "  options:\n"
	printf "  -w|--wifi-name <name>    Use <name> as SSID on the device\n"
	printf "  -s|--security <password> Use <password> for WLAN access.\n"
	printf "  -m|--message <message>   Add <message> to /etc/nonlinear-release\n"
	printf "  -p|--partition           Recreate partitions\n"
	printf "  -r|--root                Update files on root partition\n"
	printf "  -b|--boot                Update files on boot partition\n"
	printf "  -i|--install             Create install media\n"
	printf "  -v|--verbose             Be more verbose (even more if used twice)\n"
	printf "\n"
	printf "examples:\n"
	printf "  Create a new card with default values:\n"
	printf "    sudo $0 -p -b -r /dev/mmcblk0\n"
	printf "  Only change WIFI credentials on existing card:\n"
	printf "    sudo $0 -w \"MyTurboWifiName\" -s \"12345678\" /dev/sdb\n"
	printf "\n"
	exit -1
}

function debug {
	if [ ${OPT_DEBUG} -ge 1 ]; then
		printf "%s\n" "${1}"
	fi
}

function debugdebug {
	if [ ${OPT_DEBUG} -ge 2 ]; then
		printf "%s\n" "${1}"
	fi
}

# usage:
#  get_partition "/dev/sdc" "1"
#  returns "/dev/sdc1"
#  get_partition "/dev/mmcblk0" "2"
#  returns "/dev/mmcblk0p2"
function get_partition {
[[ $1 == *"/dev/mmcblk"* ]] && echo "${1}p${2}"
[[ $1 == *"/dev/sd"* ]] && echo "${1}${2}"
}

###############################################################################
# Do Pre Checks for params and stuff
###############################################################################

while [[ $# -gt 1 ]]; do
	key="$1"
	case $key in
		-w|--wifi-name)
			OPT_WIFI_NAME="$2"
			shift # shift argument value
		;;
		-m|--message)
			OPT_RELEASE_NOTE="$2"
			shift # shift argument value
		;;
		-s|--security)
			OPT_WIFI_PW="$2"
			shift # shift argument value
		;;
		*)
		# Arguments without value
		case $key in
			-p|--partition)
				OPT_RECREATE_PARTITIONS=true
			;;
			-r|--root)
				OPT_COPY_ROOTFS=true
			;;
			-b|--boot)
				OPT_COPY_BOOTFS=true
			;;
			-i|--install)
				OPT_CREATE_INSTALL_MEDIA=true
			;;
			-v|--verbose)
				OPT_DEBUG=$((OPT_DEBUG+1))
			;;
			*)
				printf "Unknown option: %s\n" "${key}"
				usage
		esac
		;;
	esac
	shift # shift argument
	DEVICE=$1
done

if [ -b "${DEVICE}" ]; then
	DEVICE_P1=$(get_partition ${DEVICE} 1)
	DEVICE_P2=$(get_partition ${DEVICE} 2)
	debug "Working on:"
	debug "  ${DEVICE}"
	debug "    ${DEVICE_P1}  boot"
	debug "    ${DEVICE_P2}  rootfs"
	debug ""
else
	printf "Device \"$1\" does not seem to be a block device!\n"
	usage
fi

debugdebug "OPT_WIFI_NAME            = $OPT_WIFI_NAME"
debugdebug "OPT_RELEASE_NOTE         = $OPT_RELEASE_NOTE"
debugdebug "OPT_RECREATE_PARTITIONS  = $OPT_RECREATE_PARTITIONS"
debugdebug "OPT_COPY_ROOTFS          = $OPT_COPY_ROOTFS"
debugdebug "OPT_COPY_BOOTFS          = $OPT_COPY_BOOTFS"
debugdebug "OPT_CREATE_INSTALL_MEDIA = $OPT_CREATE_INSTALL_MEDIA"
debugdebug "OPT_DEBUG                = $OPT_DEBUG"
debugdebug "DEVICE                   = $DEVICE"

if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root" 1>&2
	exit -1
fi

###############################################################################
# Do the actual work
###############################################################################

check_if_mounted_and_unmount

if [ ${OPT_RECREATE_PARTITIONS} = true ]; then
	rewrite_partitions
fi

mount_root
mount_boot

if [ ${OPT_COPY_ROOTFS} = true ]; then
	sync_rootfs && sync
fi

if [ ${OPT_COPY_BOOTFS} = true ]; then
	sync_bootfs && write_uenv_file && sync
fi

printf "Cleaning up...\n"

unmount_boot
unmount_root

printf "Done.\n"

