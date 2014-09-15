#!/bin/bash

HOST=$1
DISK=${2:-/dev/sda}
TARGET=${HOST}

# Cleanup old run
sudo kpartx -d ${HOST}.raw
rm ${HOST}.raw

# Create disk image
disk_size=$(ssh root@${HOST} fdisk -l ${DISK} 2> /dev/null | grep "Disk ${DISK}"|cut -f5 -d' ')
$DEBUG qemu-img create ${HOST}.raw ${disk_size} > /dev/null

# Dump and import Partition table
ssh root@${HOST} "sfdisk -d ${DISK}" 2> /dev/null | /sbin/sfdisk ${HOST}.raw > /dev/null 2>&1

# Create filesystem
$DEBUG sudo kpartx -as ${HOST}.raw
mkdir -p ${TARGET}
ssh root@${HOST} "mount|grep ^${DISK}" | while read device on mount_point type fstype options; do
  device_number=$(echo ${device} | sed "s:${DISK}::")
  $DEBUG sudo mkfs.${fstype} -F /dev/mapper/loop0p${device_number}
  $DEBUG sudo mkdir -p ${TARGET}${mount_point}
  $DEBUG sudo mount /dev/mapper/loop0p${device_number} ${TARGET}${mount_point}
done

$DEBUG sudo rsync -aAXvP root@${HOST}:/ ${TARGET}/ --delete --exclude={/dev/*,/proc/*,/sys/*,/tmp/*,/run/*,/mnt/*,/media/*,/lost+found,/home/*/.gvfs}

ssh root@${HOST} "mount|grep ^${DISK}|tac" | while read device on mount_point type fstype options; do
  device_number=$(echo ${device} | sed "s:${DISK}::")
  $DEBUG sudo umount /dev/mapper/loop0p${device_number}
done

# Create swap
for device in $(ssh root@${HOST} "swapon -s|grep ^${DISK}|cut -f1 -d' '"); do
  device_number=$(echo ${device} | sed "s:${DISK}::")
  $DEBUG sudo mkswap /dev/mapper/loop0p${device_number} > /dev/null
done

$DEBUG sudo kpartx -d ${HOST}.raw
