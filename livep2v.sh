#!/bin/bash

HOST=$1
DISK=${2:-/dev/sda}
TARGET=${HOST}
FMT=raw
PATH=/usr/bin:/usr/sbin:/bin:/sbin

# Cleanup old run
sudo qemu-nbd -d /dev/nbd0

if [ ! -f ${HOST}.${FMT} ]; then
  # Create disk image
  disk_size=$(ssh root@${HOST} LANG=C fdisk -l ${DISK} 2> /dev/null | grep "Disk ${DISK}"|cut -f5 -d' ')
  qemu-img create ${HOST}.${FMT} ${disk_size} > /dev/null || exit 1

  # Dump and import first MB (Should contain grub stage 1 and stage 1.5)
  ssh root@${HOST} "dd if=${DISK} bs=512 count=2048" | dd of=${HOST}.${FMT} bs=512 count=2048 conv=notrunc || exit 1

  # Dump and import Partition table
  ssh root@${HOST} "sfdisk -d ${DISK}" 2> /dev/null | /sbin/sfdisk ${HOST}.${FMT} > /dev/null 2>&1 || exit 1

  # Create partition mapping
  $DEBUG sudo qemu-nbd -c /dev/nbd0 ${HOST}.${FMT} || exit 1

  # Create LVM2 volume
  ssh root@${HOST} "blkid -t TYPE=LVM2_member" | while read device vars; do
    device=${device%?}
    device_number=$(echo ${device} | sed "s:${DISK}::")
    ssh -n root@${HOST} "dd if=${device} bs=512 count=24" | $DEBUG sudo dd of=/dev/nbd0p${device_number} bs=512 count=24 conv=notrunc || exit 1
    $DEBUG sudo pvs
    $DEBUG sudo lvm vgchange -ay
    ls /dev/mapper
  done

  # Create filesystem
  ssh root@${HOST} "blkid|grep -v -E 'TYPE=\"(swap|vfat|LVM2_member)\"'" | while read device vars; do
    device=${device%?}
    eval $vars
    if [[ $device =~ $DISK ]]; then
      device_number=$(echo ${device} | sed "s:${DISK}::")
      $DEBUG sudo mkfs.${TYPE} -U ${UUID} /dev/nbd0p${device_number} || exit 1
    elif [[ $device =~ /dev/mapper ]]; then
      $DEBUG sudo mkfs.${TYPE} -U ${UUID} "${device}" || exit 1
    fi
  done

  # Create swap
  for device in $(ssh root@${HOST} "swapon -s|tail -n +2|cut -f1 -d' '"); do
    if [[ $device =~ $DISK ]]; then
      device_number=$(echo ${device} | sed "s:${DISK}::")
      $DEBUG sudo mkswap -f /dev/nbd0p${device_number} || exit 1
    elif [[ $device =~ /dev/mapper ]]; then
      $DEBUG sudo mkswap -f ${device} || exit 1
    fi
  done
else
  # Create partition mapping
  $DEBUG sudo qemu-nbd -c /dev/nbd0 ${HOST}.${FMT} || exit 1
  $DEBUG sudo pvs
  $DEBUG sudo lvm vgchange -ay
fi

# Mount filesystems
$DEBUG mkdir -p ${TARGET} || exit 1

ssh root@${HOST} "mount|grep ^/dev/mapper" | while read device on mount_point type fstype options; do
  $DEBUG sudo mkdir -p ${TARGET}${mount_point} || exit 1
  $DEBUG sudo mount -t${fstype} ${device} ${TARGET}${mount_point} || exit 1
done

ssh root@${HOST} "mount|grep ^${DISK}" | while read device on mount_point type fstype options; do
  device_number=$(echo ${device} | sed "s:${DISK}::")
  $DEBUG sudo mkdir -p ${TARGET}${mount_point} || exit 1
  $DEBUG sudo mount -t${fstype} /dev/nbd0p${device_number} ${TARGET}${mount_point} || exit 1
done

# Sync files
$DEBUG sudo rsync -aAX root@${HOST}:/ ${TARGET}/ --delete --exclude={/dev/*,/proc/*,/sys/*,/tmp/*,/run/*,/mnt/*,/media/*,/lost+found,/home/*/.gvfs,/home/*,/var/lib/glance/*}

# Fix grub
for i in /dev /dev/pts /proc /sys /run; do sudo mount -B $i ${TARGET}$i; done
sudo chroot ${TARGET} grub-install --recheck /dev/nbd0
sudo chroot ${TARGET} update-grub
for i in /dev/pts /dev /proc /sys /run; do sudo umount ${TARGET}$i; done

# Unmount filesystem
ssh root@${HOST} "mount|grep ^${DISK}|tac" | while read device on mount_point type fstype options; do
  device_number=$(echo ${device} | sed "s:${DISK}::")
  $DEBUG sudo umount /dev/nbd0p${device_number} || exit 1
done

$DEBUG sudo umount /dev/mapper/*
$DEBUG sudo umount /dev/nbd0*

$DEBUG sudo lvm vgchange -an

# Delete partition mapping
$DEBUG sudo qemu-nbd -d /dev/nbd0
