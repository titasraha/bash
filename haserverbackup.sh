#!/bin/bash

SRC_SERVER=10.0.0.2;
DST_SERVER=//192.168.2.29/DiskImages;
DST_IMAGE=HomeAssistantServer/backupimage.img;
SRC_USER=pi;
DST_USER=titas;
MAP_DEVICE=/dev/mapper/loop0p2;

cleanup()
{
  umount $MAP_MOUNT
  kpartx -d -v $LOCAL_MOUNT/$DST_IMAGE
  umount $LOCAL_MOUNT
  ssh $SRC_USER@$SRC_SERVER 'sudo ./umountext4.sh'
}

if [ `/usr/bin/id -u` != 0 ]; then { echo "Sorry, must be root.  Exiting..."; exit; } fi

x=$(df -Th | tail -n +2)

while read line ; do
  MOUNT_DEVICE=$(echo $line | cut -d ' ' -f 1)
  MOUNT_PATH=$(echo $line | cut -d ' ' -f 7)
  if [ $MOUNT_DEVICE = $DST_SERVER ]; then
    LOCAL_MOUNT=$MOUNT_PATH
  fi
  if [ $MOUNT_DEVICE = $MAP_DEVICE ]; then
    MAP_MOUNT=$MOUNT_PATH
  fi
done <<< "$x"

if [ "$1" = "cleanup" ]; then
  if [ -z "$LOCAL_MOUNT" ] && [ -z "$MAP_MOUNT" ]; then
    echo "Nothing to clean up"
    exit
  fi
  cleanup
  exit
fi;

if [ -n "$LOCAL_MOUNT" ] || [ -n "$MAP_MOUNT" ]; then
  echo "File already mounted, Please run cleanup first"
  exit
fi

LOCAL_MOUNT=$(mktemp -d)
MAP_MOUNT=$(mktemp -d)

# ------------ Mount network share for backup -------------------------
mount -t cifs -o username=$DST_USER $DST_SERVER $LOCAL_MOUNT

if [ $? != 0 ]; then { echo "Local mount failure. Quitting..."; exit; } fi


# ------------ Add Device mapper ----------------------
kpartx -a -v $LOCAL_MOUNT/$DST_IMAGE
if [ $? != 0 ]; then
  echo "Unable to add device mapper.";
  umount $LOCAL_MOUNT
  exit;
fi

#ls -l /dev/mapper

# ------------ Mount the mapped file device ---------
mount $MAP_DEVICE $MAP_MOUNT
if [ $? != 0 ]; then
  echo "Unable to mount device mapped file.";
  kpartx -d -v $LOCAL_MOUNT/$DST_IMAGE
  umount $LOCAL_MOUNT
  exit;
fi


if [ "$1" = "backup" ]; then

  # ------------ Mount remote ext4 partition ----------------------------
  echo "Setting up Remote..."
  ssh $SRC_USER@$SRC_SERVER 'sudo ./mountext4.sh'

  if [ $? != 0 ]; then
    echo "Failure mounting FS on remote."
    cleanup
    exit
  fi;

  read -p "Enter notes for backup: " BACKUP_DESC

  # ------------- Delete left over directory from previous failed attempt ----------------
  if [ -d $MAP_MOUNT/extfs.tmp ] ; then                 \
    rm -rf $MAP_MOUNT/extfs.tmp ;                       \
  fi ;

  if [ -d $MAP_MOUNT/extfs ] ; then                     \
    NEWSNAPSHOTNAME=`/bin/date -r $MAP_MOUNT/extfs "+%F-%H%M%S"`
    cp -al $MAP_MOUNT/extfs $MAP_MOUNT/extfs.tmp ;     \
  fi;

  rsync -vax --delete --rsync-path="sudo rsync"  $SRC_USER@$SRC_SERVER:/mnt/ext4/ $MAP_MOUNT/extfs.tmp > info_log.txt

  mv $MAP_MOUNT/extfs $MAP_MOUNT/extfs_$NEWSNAPSHOTNAME ;
  mv $MAP_MOUNT/extfs.tmp $MAP_MOUNT/extfs ;

  # step 4: update the mtime of extfs to reflect the snapshot time
  touch $MAP_MOUNT/extfs ;

  NEWBACKUPINFO=`/bin/date -r $MAP_MOUNT/extfs "+%F-%H%M%S"`
  echo "$NEWBACKUPINFO: $BACKUP_DESC" >> $MAP_MOUNT/backup_info.txt

  cleanup

  echo "All Done."
fi
