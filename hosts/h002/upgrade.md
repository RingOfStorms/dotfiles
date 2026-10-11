# h002 internals upgrade plan

Goal: replace the ~2012 platform (i7-3770K + HD 7950) with a modern, low-idle-power
board/CPU/RAM in the existing Fractal case. Storage-only role; headroom for future services.

## Chosen bundle (Micro Center)

**Intel Core Ultra 5 250K+ 3-in-1 bundle — $529.99** (reg. $829.97)

| SKU | Item |
|---|---|
| 994293 | Intel Core Ultra 5 250K+ (has integrated graphics) |
| 804971 | Gigabyte B860 DS3H WiFi6E (LGA 1851, ATX) |
| 548628 | G.Skill Ripjaws S5 32GB DDR5-6000 kit |

Why this one:
- Cheapest bundle **with an iGPU**. Boots headless or on onboard video; no discrete GPU needed.
- B860 is enough; Z890 boards add cost, not NAS value.
- Arrow Lake idles low and has Quick Sync, which helps if media services move here later.

Rejected:
- **250KF+ bundles ($499.99 / $549.99):** the "F" means no iGPU, so they'd need a GPU to boot, which is the problem being fixed.
- **250K+ with MSI Z890-S Pro ($579.99):** +$50 for overclocking features a NAS doesn't use.
- **Ultra 7 / Ultra 9 / Xeon:** overkill for storage.

Check in-store before buying:
- [x] B860 DS3H has **4× SATA** + 2× M.2 (M key). 5 HDDs need an add-in SATA card (below).
- [ ] Check the manual for whether either M.2 slot disables a SATA port; put the boot NVMe in a slot that doesn't.
- [ ] Board BIOS supports the 250K+ out of the box (ask store to flash if not; or use Q-Flash Plus).
- [ ] Compare against a non-bundle i5-14400 / 12400 (non-F) + B760 DDR4 board + 16–32 GB DDR4 online. Only worth it if clearly < ~$400 total; old DDR3 cannot be reused either way.

## Remaining parts

| Part | Pick | Est. |
|---|---|---|
| Boot drive | **Inland TN320 256GB NVMe** (SKU 529750), PCIe 3.0 x4, TLC. Plenty for NixOS boot/root; don't use a SATA SSD (takes a SATA port) | $59.99 |
| CPU cooler | **Thermalright Peerless Assassin 140 Black (SKU 959437)** (158 mm tall; 1× 140 mm + 1× 120 mm fan). Fit check: measure from the CPU heatspreader (or socket top) to the inside of the side panel; need > 158 mm + a few mm margin. Tray-to-panel measurements overstate clearance. Fallback if tight: Assassin X120 Refined SE (~148 mm). Confirm LGA 1851 mounting in box | $59.99 |
| PSU | **Corsair RM1000x (SKU 769588)**, ATX 3.1, Gold, fully modular, 12 SATA connectors in box (no extra cables needed). Chosen over RM750e for SATA count/upgradability; check length fits beside the bottom drive cage | $179.99 |
| SATA cables | Usually included with the board | $0–10 |
| SATA card (**required** for 5th HDD) | **Vantec UGT-ST655** 5-port PCIe x4 (expected JMB585, verify on box; no port multipliers). Put it in the free x16 slot (no GPU). ASM1166 is equally fine if found | $49.99 |
| 5th HDD | WD Red Plus 12TB CMR (SKU 913160) | $459.99 |

Cart total: **$1,339.94** ($529.99 bundle + $179.99 PSU + $459.99 HDD + $49.99 SATA card + $59.99 NVMe + $59.99 cooler), before tax. SATA data cables: reuse the old ones (need 5; board includes ~2).

## Current storage (from `lsblk`)

| Device (at time of capture) | Model | Size | Fate |
|---|---|---|---|
| sda, sdb, sde, sdf | Seagate IronWolf Pro ST12000NT001 | 12 TB each | Keep (data pool) |
| sdc | Seagate ST750LX003 (2.5" SSHD) | 750 GB | Retire (after removal from pool) |
| sdd | Kingston SV300S37A120G SSD | 120 GB | Old boot; keep as fallback, then retire |

`/dev/sdX` names change between boots. Always identify drives by `/dev/disk/by-id/` + serial.

## Phase 1: before buying/opening (on current hardware)

### 1. Verify backups FIRST
Before touching the pool:
- [ ] Identify what in `/data` is irreplaceable (photos, documents, etc.) vs re-downloadable media.
- [ ] Confirm a recent, **restorable** copy of the irreplaceable data exists off this machine (test-restore a few files).
- [ ] Do not continue until this is true.

### 2. Inspect live pool state
The format comment in `hardware-configuration.nix` (replicas=2, five disks) is historical; check the live state:
```sh
ls -l /dev/disk/by-id/ | grep -v part          # map by-id/serial -> sdX
bcachefs fs usage -h /data                     # members, replicas, free space, per-device usage
bcachefs show-super /dev/disk/by-id/<any-ironwolf-id> | grep -iE 'uuid|replicas|device'
dmesg | grep -i bcachefs | tail -50            # any errors?
for d in /dev/disk/by-id/ata-ST*; do case $d in *-part*) ;; *) smartctl -H -A "$d";; esac; done
```
Record:
- [ ] by-id path + serial of the 750 GB ST750LX003
- [ ] Whether it is actually a pool member
- [ ] Data/metadata replica settings
- [ ] Free space on the four 12 TB drives is enough to absorb its data
- [ ] All drives healthy (no reallocated/pending sectors growing)

### 3. Remove the 750 GB drive from the pool (only if it is a member)
```sh
SSHD=/dev/disk/by-id/ata-ST750LX003-1AC154_<SERIAL>
bcachefs device evacuate "$SSHD"
bcachefs fs usage -h /data        # confirm its usage is 0 and evacuate completed without errors
bcachefs device remove "$SSHD"
bcachefs fs usage -h /data        # confirm it is no longer listed
```
- [ ] Evacuate finished successfully
- [ ] Remove succeeded and the device is gone from `fs usage`
- [ ] Only now is it safe to physically disconnect it

### 4. Record the rest
```sh
bcachefs show-super /dev/disk/by-id/<ironwolf-id> | grep -i uuid   # expect external UUID 53a26b95-...
```
- [ ] PSU model/wattage/80+ rating (reuse decision)
- [ ] Copy of current NFS export config and clients (h001 nixarr etc.) to re-test later

## Phase 2: prepare NixOS config

Plan: **fresh UEFI install on the new NVMe**; the old boot is legacy GRUB pinned to the Kingston
(`boot.loader.grub.device = ".../ata-KINGSTON_SV300S37A120G_..."` in `flake.nix`).

- [ ] Partition NVMe GPT: 1 GB EFI (vfat) + root (ext4). `hosts/testbed/disko-config.nix` as a template.
- [ ] `nixos-generate-config` → replace `hardware-configuration.nix`; carry over the `/data` block
      (`UUID=53a26b95-941b-4f41-b049-c166905ed8c2`, `bcachefs`, `nofail`, `x-systemd.device-timeout=600s`)
      and `boot.supportedFilesystems = [ "bcachefs" ];`.
- [ ] In `flake.nix`: drop the `boot_grub` module and the `grub.device` override; add
      `boot.loader.systemd-boot.enable = true;` and `boot.loader.efi.canTouchEfiVariables = true;`.
- [ ] Ensure `nvme` is in `boot.initrd.availableKernelModules` (generated config should add it).
- [ ] Restore SSH host keys / sec-agent identity so secrets keep working, or re-enroll the host.
- [ ] Remove the swap UUID from the old disk; add new swap (file or partition) if wanted.
- [ ] Update `readme.md` hardware table after the swap.

## Phase 3: hardware swap

1. Shut down, unplug, hold power button to drain. Label each IronWolf SATA cable with its serial.
2. Remove: HD 7950, old board/CPU/RAM, ST750LX003 (only after Phase 1 step 3), Kingston SSD (keep aside as fallback).
   - **If replacing the PSU: remove ALL old PSU cables, including every SATA power harness.** Use only the cables that came with the new PSU. Modular cables are not standardized between brands or even models; a connector that fits can have a different pinout and kill every drive on that harness at once.
3. Out of case: install CPU, cooler (LGA 1851 bracket), RAM (slots per manual, usually A2/B2), NVMe in the CPU-attached M.2 slot.
4. Install I/O shield, check standoffs for ATX layout, mount board.
5. Connect 24-pin, 8-pin EPS, front panel, USB headers, case fans.
6. Connect HDDs: the 4 IronWolfs to onboard SATA ports not shared with populated M.2 slots; the new WD Red Plus to the Vantec UGT-ST655 card. Do **not** add the WD to the pool yet.
7. Monitor to the **motherboard** video output.

## Phase 4: BIOS settings

- [ ] Update BIOS to latest (Q-Flash).
- [ ] UEFI boot, CSM disabled.
- [ ] XMP on (optional for NAS; off = slightly lower power).
- [ ] AC power loss restore → **Power On**.
- [ ] ASPM enabled, C-states Auto/enabled (deepest available).
- [ ] Disable unused: RGB, Wi-Fi/Bluetooth (if wired), unused controllers.
- [ ] Quiet fan curves; keep drives < ~45 °C.

## Phase 5: install & verify

1. Boot NixOS installer (USB), install with the config from Phase 2.
2. Verify:
```sh
lsblk -o NAME,SIZE,MODEL,SERIAL,ROTA,TRAN      # 4x IronWolf + WD Red Plus (unused) + NVMe
findmnt /data
bcachefs fs usage -h /data                     # 4 members, expected replicas, no errors
dmesg | grep -i bcachefs
for d in /dev/disk/by-id/ata-ST12000NT001* /dev/disk/by-id/ata-WDC_WD120EFGX*; do case $d in *-part*) ;; *) smartctl -H "$d";; esac; done
```
   Check the WD's by-id name with `ls /dev/disk/by-id/ | grep -i wd`; adjust the glob if the model string differs.
3. Only after the 4-disk pool mounts cleanly and shows no errors, add the 5th drive:
```sh
smartctl -t long /dev/disk/by-id/<wd-id>        # optional burn-in first; wait for it to finish
bcachefs device add /data /dev/disk/by-id/<wd-id>
bcachefs fs usage -h /data                     # now 5 members, no errors
```
4. Check NFS exports from clients (h001 nixarr / media mounts).
5. Power tuning:
```sh
nix-shell -p powertop --run "sudo powertop"    # aim for package C8+ at idle
```
   Consider `powerManagement.powertop.enable = true;` (test for USB/NIC side effects).
6. Measure wall power (Kill-A-Watt / smart plug) idle and under scrub; compare to before.

## Expected result

- Idle: ~25–35 W with 4 drives spinning (vs. est. 80–100 W+ now).
- No HD 7950 fan; quiet tower cooler at idle.
- New PSU/board replace ~14-year-old components.
- Headroom (6P+12E cores, 32 GB, Quick Sync) to move media services here later if desired.

## Retire after success
- [ ] ST750LX003 SSHD
- [ ] Kingston SV300 SSD (after a few weeks of stable boots)
- [ ] HD 7950, i7-3770K, old board, DDR3 (sell or recycle)
