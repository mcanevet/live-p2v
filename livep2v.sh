#!/bin/bash

HOST=$1
DISK=${2:-/dev/sda}
TARGET=${HOST}
FMT=qcow

# Cleanup old run
sudo kpartx -d ${HOST}.${FMT} 2> /dev/null

if [ ! -f ${HOST}.${FMT} ]; then
  # Create disk image
  disk_size=$(ssh root@${HOST} fdisk -l ${DISK} 2> /dev/null | grep "Disk ${DISK}"|cut -f5 -d' ')
  $DEBUG qemu-img create ${HOST}.${FMT} ${disk_size} > /dev/null

  # Dump and import Partition table
  ssh root@${HOST} "sfdisk -d ${DISK}" 2> /dev/null | /sbin/sfdisk ${HOST}.${FMT} > /dev/null 2>&1

  # Create partition mapping
  $DEBUG sudo kpartx -as ${HOST}.${FMT}

  # Create filesystem
  mkdir -p ${TARGET}
  ssh root@${HOST} "mount|grep ^${DISK}" | while read device on mount_point type fstype options; do
    device_number=$(echo ${device} | sed "s:${DISK}::")
    $DEBUG sudo mkfs.${fstype} -F /dev/mapper/loop0p${device_number}
  done

  # Create swap
  for device in $(ssh root@${HOST} "swapon -s|grep ^${DISK}|cut -f1 -d' '"); do
    device_number=$(echo ${device} | sed "s:${DISK}::")
    $DEBUG sudo mkswap -f /dev/mapper/loop0p${device_number} > /dev/null
  done
else
  # Create partition mapping
  $DEBUG sudo kpartx -as ${HOST}.${FMT}
fi

# Mount filesystems
ssh root@${HOST} "mount|grep ^${DISK}" | while read device on mount_point type fstype options; do
  device_number=$(echo ${device} | sed "s:${DISK}::")
  $DEBUG sudo mkdir -p ${TARGET}${mount_point}
  $DEBUG sudo mount -t${fstype} /dev/mapper/loop0p${device_number} ${TARGET}${mount_point}
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
