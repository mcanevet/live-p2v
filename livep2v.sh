#!/bin/bash

HOST=$1
DISK=${2:-/dev/sda}
TARGET=${HOST}
FMT=raw

# Cleanup old run
sudo kpartx -d ${HOST}.${FMT} 2> /dev/null

if [ ! -f ${HOST}.${FMT} ]; then
  # Create disk image
  disk_size=$(ssh root@${HOST} LANG=C fdisk -l ${DISK} 2> /dev/null | grep "Disk ${DISK}"|cut -f5 -d' ')
  qemu-img create ${HOST}.${FMT} ${disk_size} > /dev/null || exit 1

  # Dump and import Partition table
  ssh root@${HOST} "sfdisk -d ${DISK}" 2> /dev/null | /sbin/sfdisk ${HOST}.${FMT} > /dev/null 2>&1 || exit 1
  ssh root@${HOST} "dd if=${DISK} bs=512 count=1" | dd of=${HOST}.${FMT} bs=512 count=1 conv=notrunc || exit 1

  # Create partition mapping
  $DEBUG sudo kpartx -as ${HOST}.${FMT} || exit 1

  # Create filesystem
  mkdir -p ${TARGET} || exit 1
  ssh root@${HOST} "blkid|grep ^${DISK}|grep -v -E 'TYPE=\"(swap|vfat)\"'" | while read device vars; do
    device=${device%?}
    device_number=$(echo ${device} | sed "s:${DISK}::")
    eval $vars
    $DEBUG sudo mkfs.${TYPE} -U ${UUID} /dev/mapper/loop0p${device_number} || exit 1
  done

  # Create swap
  for device in $(ssh root@${HOST} "swapon -s|grep ^${DISK}|cut -f1 -d' '"); do
    device_number=$(echo ${device} | sed "s:${DISK}::")
    $DEBUG sudo mkswap -f /dev/mapper/loop0p${device_number} > /dev/null || exit 1
  done
else
  # Create partition mapping
  $DEBUG sudo kpartx -as ${HOST}.${FMT} || exit 1
fi

# Mount filesystems
ssh root@${HOST} "mount|grep ^${DISK}" | while read device on mount_point type fstype options; do
  device_number=$(echo ${device} | sed "s:${DISK}::")
  $DEBUG sudo mkdir -p ${TARGET}${mount_point} || exit 1
  $DEBUG sudo mount -t${fstype} /dev/mapper/loop0p${device_number} ${TARGET}${mount_point} || exit 1
done

# Sync files
$DEBUG sudo rsync -aAXvP root@${HOST}:/ ${TARGET}/ --delete --exclude={/dev/*,/proc/*,/sys/*,/tmp/*,/run/*,/mnt/*,/media/*,/lost+found,/home/*/.gvfs}
$DEBUG sync

# Unmount filesystem
ssh root@${HOST} "mount|grep ^${DISK}|tac" | while read device on mount_point type fstype options; do
  device_number=$(echo ${device} | sed "s:${DISK}::")
  $DEBUG sudo umount /dev/mapper/loop0p${device_number} || exit 1
done

# Delete partition mapping
$DEBUG sudo kpartx -d ${HOST}.${FMT}
