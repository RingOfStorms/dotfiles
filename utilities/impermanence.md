# Impermanence


## Look at file changes from last root

```sh
sudo mkdir -p /btrfs-top
sudo mount -o subvolid=5 /dev/mapper/cryptroot /btrfs-top
LATEST_SNAPSHOT=$(sudo ls -t /btrfs-top/old_roots/ | head -n 1)
SNAPSHOT_PATH="/btrfs-top/old_roots/$LATEST_SNAPSHOT"
echo "Comparing against snapshot: $SNAPSHOT_PATH"

# Option A: rsync
sudo rsync -rcai --delete --dry-run \
  --exclude='/@*' \
  --exclude='/nix' \
  --exclude='/proc' \
  --exclude='/sys' \
  --exclude='/dev' \
  --exclude='/tmp' \
  --exclude='/boot' \
  --exclude='/persist' \
  --exclude='/.snapshots' \
  --exclude='/.swap' \
  /var/lib/ $SNAPSHOT_PATH/var/lib/

# Option B: diff (Can be very noisy, but effective)
sudo diff -qr /var/lib $SNAPSHOT_PATH/var/lib
```
