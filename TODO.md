# TODO

Running list of what's outstanding. Status of what's *done* lives in
[DOC/README.md](DOC/README.md); this file is only the open items.

## Blocking the Phase 5 image

- [x] **FAT size: settled at DietPi's stock 128 MB, do not repartition**
      (2026-07-29). 512 MB was the original plan, 256 MB briefly replaced it, and
      both were reverted: ~97 MB free already holds thousands of `.PRG` files,
      and the space is worth more to the root filesystem on a 4 GB card.
      Enlarging it is not free — it means rewriting the partition table offline,
      which is exactly what let an unbootable image through (see below).
      `refit-fat.sh` still does it if a future release needs it; the default is
      now `-FatMB 0`, no refit.

- [x] **THE DISK IDENTIFIER TRAP — cost a full flash-and-fail cycle.**
      `cmdline.txt` pins `root=PARTUUID=6a31ef16-02`. On MBR that is *derived*
      from the disk signature, not stored — so PiShrink deleting and recreating
      the last partition with `parted` gave the image a new signature and the
      kernel could no longer find its own root filesystem. Symptom: display wakes
      (firmware and `start4.elf` were fine), then black forever, no message,
      because `rootwait` + `quiet loglevel=0`. The image mounted perfectly on a
      PC and every boot file was byte-identical to a working build.
      Now fixed in two places: `shrink-image.sh` records the id before PiShrink
      and restores it with `sfdisk --disk-id`, and `check-image.sh` **fails** an
      image whose `cmdline.txt` PARTUUID or `fstab` UUIDs do not resolve against
      the actual image. Worth remembering generally: an identifier derived from
      something else can be invalidated by a tool that never touched the file
      containing it.

- [x] **Superseded and closed — FAT ships at DietPi's stock 128 MB.** Was: build
      the image with a 256 MB FAT partition.
      Layout decided and verified on hardware 2026-07-25 — see DOC/07 Part A2.
      FAT is fixed at build time (PiShrink expands root, never FAT), so it must
      fit a 4 GB card. **Revised 512 MB → 256 MB (2026-07-29):** a built image has
      222 MB free at 256 MB, so the other 256 MB is worth more to the root.
      The tooling exists and is tested — `scripts/release/refit-fat.sh`, offline
      between capture and shrink, because FAT cannot be grown on a running Pi
      (the root's start would have to move). It preserves the MBR disk id, the
      root filesystem UUID and the FAT volume serial, so the PARTUUID/UUID
      warning below turned out to be avoidable: **no edits to `cmdline.txt` or
      `/etc/fstab` are needed.** Verified 128 → 256 MB on a real build.
      Library stays on ext4; `mount --bind /boot/firmware/x16 <fsroot>/FAT-FILES`
      exposes the PC-writable folder inside it. Confirmed: CD/DIR/LOAD all work
      in subdirectories, and SAVE writes back through the bind mount onto FAT.
      The bind-mount is **done** — `drop_attach()` in `custom.sh`, folder named by
      `X16_DROP_DIR` (default `FAT-FILES`), deployed and verified on the dev Pi.
      Remaining work: run `refit-fat.sh` as part of the real release capture.
      (`dist/fat-x16-README.TXT` *is* already in the folder.)

- [ ] **The shipped image must not carry the dev Pi's Wi-Fi state.** The image
      has to ship with `X16_WIFI_SSID=`/`X16_WIFI_PSK=` empty, a valid
      `X16_WIFI_COUNTRY`, and **no** `.x16-wifi.state` / `.x16-wifi.nohardware` /
      `x16-wifi-status.txt` on the FAT partition. Handled by
      `prep-image-source.sh`, enforced by `check-image.sh` — which confirmed
      `x16RasPi4-try6.gz` ships both the stamp and our credentials.
      The stamp itself is now **gone from the design**: the applier clears the
      card on a successful join instead (2026-07-29), so a stale stamp can no
      longer exist to be shipped. `.x16-wifi.state` is deleted on sight.
      **Host keys: DECIDED — ship them as they are (2026-07-30).** The dev Pi's
      dropbear host keys are baked in, so every unit flashed from this image
      shares one SSH identity. Accepted knowingly: SSH here is a service-tool path
      on an appliance with no shell, not an exposed surface, and the only safe
      alternative is `--reset-host-keys` — dropbear runs without `-R`, so simply
      deleting the keys ships an image with no SSH at all.
      `check-image.sh` still WARNs, which is right: that warning is now the record
      of the decision, not an outstanding task. Revisit only if a unit is ever put
      on an untrusted network.

      **Country code SETTLED: `US` everywhere (2026-07-30.)** It had shipped
      split — card and ext4 template `US`, both `dietpi.txt` copies `GB`, README
      example `GB` — and "cosmetic" was the wrong reading of the `dietpi.txt`
      half: `dietpi-config` and DietPi updates act on
      `AUTO_SETUP_NET_WIFI_COUNTRY_CODE` via `dietpi-set_hardware`, so the
      regulatory domain could change under a unit already in an owner's hands,
      with a symptom indistinguishable from a wrong passphrase. Note there are
      **two** `dietpi.txt` files on Bookworm, not one — `/boot/dietpi.txt` on the
      ext4 root and `/boot/firmware/dietpi.txt` on the card, separate files with
      identical content, and both said `GB`.
      Now `US` in: `config/x16-wifi.conf`, the applier's fallback default
      (`scripts/x16-wifi-apply.sh`), `scripts/x16-wifi.sh`'s `wpa_supplicant`
      header, and the end-user README. `prep-image-source.sh` rewrites the card,
      the ext4 reset template and both `dietpi.txt` copies to agree;
      `check-image.sh` **fails** an image where the template or either
      `dietpi.txt` disagrees with the card, and warns if the card ships anything
      other than `US`. Applied to the dev Pi 2026-07-30 and all four verified.
      The template mattered separately: the applier rebuilds the card from it
      after a successful join, so a stale country there reappears *later* rather
      than at capture.
      **Consume-and-clear is now verified on hardware (2026-07-29).** A real Pi 4
      read credentials off the card, enabled the radio, rebooted itself once,
      joined the AP at 192.168.1.194, cleared its own `x16-wifi.conf` keeping
      `X16_WIFI_COUNTRY=US`, and wrote the "Connected" status file. A further
      reboot brought Wi-Fi up on its own from a blank card in 13 s. Full
      sequence in `x16-appliance.log`: modules → interface after 1 s → reg
      domain → rfkill → `wpa_supplicant.conf` → `allow-hotplug` → associated
      after 5 s → card cleared.

## Phase 5 — harden & package ([DOC/07](DOC/07-phase5-harden-package.md))

The release itself is now scripted end to end — `scripts/release/`, driven from
Windows by `make-release.ps1` through WSL. What's left is running it on an image
that's actually ready.

- [x] **Clean the FAT partition before imaging** — automated in
      `prep-image-source.sh` (dry-run by default) and asserted by
      `check-image.sh`. The dev Pi still has all eleven `config.txt.bak-*` /
      `cmdline.txt.bak-*` files and `System Volume Information`; they are also
      still inside `x16RasPi4-try6.gz`.
- [x] **Re-arm DietPi's first-boot resize before every capture.** Its first act
      is to delete its own `WantedBy` symlink, so it reads `disabled` on any Pi
      that has booted twice, and an image captured from one never expands.
      `prep-image-source.sh` does it; `check-image.sh` fails the image without
      it. **Power off, don't reboot** — a reboot disarms it again.
- [x] **PiShrink vendored** at a pinned commit in `tools/pishrink/`, always
      invoked `-s -n`: its own autoexpand is Raspberry Pi OS shaped
      (`/etc/rc.local` + `raspi-config`, neither of which exists on DietPi).

- [x] **Harden the SD card — already done, nothing to install.** DietPi ships its
      own RAMlog and has it on by default: `/var/log` is a 50 MB tmpfs straight
      from `/etc/fstab`, verified on the dev Pi and in a built image. The old
      plan here (`dietpi-software install 137`, log2ram) was **wrong** — it would
      have layered a second log-in-RAM system onto one already running. Not the
      read-only overlay either: it would silently discard SAVEs into the ext4
      library *and* the Wi-Fi credentials the applier now stores there (DOC/07
      Part A2). `check-image.sh` fails an image whose `/var/log` is not a tmpfs.
- [x] **Power-cut resilience — accepted as verified by the owner, 2026-07-30.**
      Pulling power mid-session "many times, it's fine". Not instrumented and not
      re-run here, so this is an owner judgement rather than a captured result —
      recorded as such deliberately, because the DietPi-RAMlog design above is
      what it is testing and that part *is* verified in the image.
- [x] **The serial console disagreement — SETTLED 2026-07-30, both copies now
      `=0`.** Unblocked by narrowing to the Pi 4: it had been left open *only*
      because on a Pi 3 `ttyS0` can be a genuine console rather than the not-ready
      mini-UART it is on a Pi 4, which made blanket-disabling risky. No Pi 3, no
      risk, and nothing here uses a serial console.
      Set on the dev Pi in **both** `dietpi.txt` files (Bookworm has one on ext4 and
      one on the card — separate files, both said `1`).
      `prep-image-source.sh` now enforces it on both, and `check-image.sh` was
      upgraded from WARN to **FAIL** on both, because with prep enforcing it a
      disagreement now means prep did not run rather than that somebody chose
      differently. That removes one of the two standing warnings on the build.
      `enable_uart=1` stays in `config.txt` — it pairs with `dtoverlay=disable-bt`
      and does not create a getty by itself. Verified, not assumed.

      Original finding, for the record — checked on the dev Pi 2026-07-29:

      | | |
      |---|---|
      | `serial-getty@ttyS0` | `disabled` / `inactive` — correct |
      | `cmdline.txt` | `console=tty1` only, no `console=ttyS0` — correct |
      | `dietpi.txt` | **`CONFIG_SERIAL_CONSOLE_ENABLE=1`** — disagrees |

      `trim-boot.sh` turned the unit off (it was waiting out a 90 s device
      timeout every boot — see the boot-time section below), but nothing changed
      DietPi's own setting. `dietpi-config` and DietPi updates read that key and
      run `dietpi-set_hardware serialconsole`, so the getty can come back on its
      own, on a shipped unit, and the symptom is a silent 90 s stall.
      Decide and make the two agree before capture — almost certainly by setting
      `CONFIG_SERIAL_CONSOLE_ENABLE=0`, since nothing here uses a serial console.
      `check-image.sh` now asserts both halves (unit not enabled = FAIL, setting
      disagreeing = WARN) and flags this on the current build, so it cannot drift
      back unnoticed.
      Related: `enable_uart=1` is in `config.txt` (it pairs with
      `dtoverlay=disable-bt`); it does not create a getty by itself, so it is not
      the boot-time problem — worth confirming rather than assuming.
      On a **Pi 3** this needs care: `ttyS0` there may be a genuine console
      rather than the not-ready mini-UART it is on a Pi 4.

- [x] **Re-captured with the Wi-Fi fixes: `x16-appliance-r49.img.gz`, 574 MB,
      `sha256 f4699073925346ce3b22abf52560093142aa82d5e10117f12404b6583a3de962`**
      (2026-07-29, second capture of the day). Taken from the *8 GB test card*,
      not the 4 GB golden master — that card is byte-for-byte the golden card's
      content plus the four applier fixes, so capturing it kept the 4 GB card
      untouched as a rollback instead of consuming it.
      `prep --apply` (20 changes) → capture 7.96 GB in 936 s at 8.5 MB/s →
      check → PiShrink 7.5 G → 2.4 G → compress. Full audit re-run on the
      *decompressed shipped artifact*: **no failures, 2 warnings** (the serial
      setting and the SSH host keys, both open decisions below).
      **The disk-id trap fired again and the fix caught it:** PiShrink rewrote
      the signature `0x6a31ef16 → 0xaa6ff0b5`, `shrink-image.sh` restored it, and
      the post-shrink re-check confirmed `root=PARTUUID=6a31ef16-02` still
      resolves. Without that restore this would have been a second unbootable
      image, identical in symptom and just as silent. `resize2fs -M` landed at
      594519 blocks against the 590005 that `resize2fs -P` predicted.
      **Flashed and booted clean on the Pi 4 (2026-07-29).** Boot #1 of the new
      image: the resize genuinely expanded this time — 594519 → 1910784 4k
      blocks, so `df` shows 7.2 G root with 5.5 G free — where the previous
      card's resize was a no-op because it came from an already-expanded source.
      Emulator launched at 9.73 s. FAT 97 MB free, drop folder bound, 26-entry
      library present.
      The two fixes that mattered are confirmed from a cold flash:
      `x16-wifi-status.txt` **exists out of the box** reading "Wi-Fi is not set
      up… nothing is wrong - this is how a new card comes", and both Wi-Fi
      off-switches ship intact (overlay + module blacklist, `eth0` only).
      Zero dev-Pi residue: no `.bak` files, no `wpa_supplicant` configs, blank
      card, empty `bash_history`. The only two files under `/opt/x16` and
      `/root/.cache` that look like litter (`.x16-wifi-status.last`, the mesa
      shader cache) were **regenerated this boot** — mtimes 07:25 and 07:26
      against 05:47 for the shipped files — so prep did remove them.
      Keep `x16-appliance-r49-128fat.img.gz` as the rollback until the Pi 3 leg
      passes; it differs only by the applier fixes.

- [x] **Capture the image: done end to end 2026-07-29 (superseded by the
      re-capture above, which carries the Wi-Fi fixes).**
      `prep --apply` → capture over SSH (3.997 GB, 412 s, 9.7 MB/s) → refit to
      256 MB → check → PiShrink. Result: **`x16-appliance-r49.img.gz`, 578 MB**,
      `sha256 2285ae279f017a958b823422592ef0620f4fad9c9ccc6da86e0014814ceff544`.
      Ship check on the unpacked artifact: **no failures, 2 warnings** (SSH host
      keys baked in; the serial-console setting above). PiShrink logged
      "Skipping autoexpanding process..." as intended, and repaired the live
      capture's dirty journal on the way through, as predicted.
- [x] **Pi 4 leg passed, 2026-07-29** — `x16-appliance-r49-128fat.img.gz` on a
      blank 8 GB card, inspected over SSH on boot #1 (uptime 128 s, one boot ID
      in the journal, so all of this is genuinely first-boot behaviour):
      | Checked | Result |
      | --- | --- |
      | `root=PARTUUID=6a31ef16-02` resolves | disk id `0x6a31ef16` — the trap above is closed |
      | auto-expand | p2 2.3 G → 7.3 G, `df` root 7.2 G, 5.5 G free |
      | FAT | 131 MB, 34 MB used, **97 MB free** — matches the README's "around 100 MB" |
      | emulator | running, `-fullscreen -scale 3 -widescreen -joy1`, launch at 10.05 s |
      | boot | 1.6 s kernel + 16.1 s userspace; `custom.sh` in at 8.87 s |
      | `FAT-FILES` bind mount | live, `p1[/x16]` → `/mnt/x16/FAT-FILES` |
      | DietPi-RAMlog | `/var/log` tmpfs, 50 MB |
      | Wi-Fi credentials | none — `dietpi-wifi.txt` blank, `/etc/wpa_supplicant` stock only |
      | radio | `dtoverlay=disable-wifi` honoured, `eth0` only |
      | serial getty | `ttyAMA0` masked, `ttyS0` disabled |
      | splash + EDID | all three blobs and both EDIDs present |
      Note the clock jumps around in the journal (05:17 → 05:59 → 07:01) because
      fake-hwclock restores the build-time clock and NTP then corrects it
      mid-boot. Only the uptime-relative figures in `x16-appliance.log` mean
      anything; wall-clock deltas in `systemctl status` are noise.
- [x] **Pi 3 leg — DROPPED 2026-07-30, the release is Pi 4 only.** Never run on
      hardware, so two-model support is not a claim this project makes. Original
      scope kept below for the record.
      ~~Pi 3 leg~~ — the same card into the Pi 3 for Gate 5's second-Pi
      requirement, plus non-HDMI display detection and the Pi 3's different Wi-Fi
      chip. Note the image ships `X16_OUTPUT=1080p` / `hdmi_mode=16`; if the TV
      needs it, `X16_OUTPUT=720p` in `x16.conf` is a card edit, not a re-image —
      the 720p EDID and the 1280x720 splash blob are both already in the image.
      The clone is a full system with SSH, so iterate on *it* over SSH rather
      than re-capturing — the dev card stays a golden master.

- [ ] **Consume-and-clear empties the FILE; it does not scrub the CARD.**
      Measured on the cold-flashed card 2026-07-29, after a real join:
      | offset | contents |
      | --- | --- |
      | 36,317,407 | the live `x16-wifi.conf` — blank, as intended |
      | 68,192,405 | `X16_WIFI_SSID=kentwa` / `X16_WIFI_PSK=rocket123`, intact |
      `grep -c rocket /dev/mmcblk0p1` finds it; nothing at the filesystem level
      does. The cause is **the Windows editor, not our scrub**: editors save
      atomically — write a fresh copy, then repoint the directory entry — so by
      the time the applier rewrites `x16-wifi.conf`, the plaintext is sitting in
      a cluster the file no longer owns. Overwriting the file in place, however
      carefully, cannot reach it. Only wiping the FAT's free space can.
      `dist/README-end-user.md` no longer claims the password is cleared "off
      the card" (it said that, and it was false) and now tells an owner to
      reformat before giving the card away.
      **Decision needed** — leave it, or wipe free space after a successful join:
      ~97 MB of writes once per Wi-Fi setup, backgrounded so it does not delay
      the emulator, needing a headroom margin so an owner's `SAVE` cannot hit
      disk-full mid-wipe and a startup guard to delete the fill file if the power
      is cut during it. Cheap in card wear; the failure modes are the real cost.

- [x] **DietPi disables Wi-Fi TWICE, and we only ever undid one of them — fixed
      2026-07-29.** Removing `dtoverlay=disable-wifi` puts the chip back on the
      SDIO bus (`dmesg`: "mmc1: new high speed SDIO card at address 0001") but
      `/etc/modprobe.d/dietpi-disable_wifi.conf` blacklists `brcmutil`,
      `brcmfmac` and `cfg80211`, so the driver never binds. The applier waited
      its 20 s, found no interface, and told the owner **"This Pi does not
      appear to have Wi-Fi"** — on a Pi 4 with working onboard Wi-Fi, whose AP
      was in range the whole time. A hand `modprobe brcmfmac` produced `wlan0`
      instantly, which is what identified it.
      The applier now removes the blacklist (renamed to `.bak-x16wifi`, inert
      because modprobe.d only reads `*.conf`) and loads the listed modules in
      reverse file order — `cfg80211` before the driver that needs it. It reads
      the module names back out of the file rather than hardcoding `brcmfmac`,
      so a USB adapter takes the same path. Done *before* the reboot branch, so
      the next boot autoloads from the SDIO modalias and the interface is simply
      there. `prep-image-source.sh` restores the blacklist, re-comments
      `allow-hotplug wlan0`, and clears the `.bak-x16wifi` files, so a Pi used to
      test Wi-Fi can still be captured as a clean Ethernet-only image.
      Worth generalising: **a feature switched off by a distro is usually
      switched off in more than one place.** We verified the overlay handling
      worked and stopped looking.

- [x] **A blank card means two opposite things — caught 2026-07-29, on the boot
      right after the first successful join.** Writing a status file on the
      blank-SSID path (see below) meant a Pi that had *just* connected and
      cleared its own card was then told "Wi-Fi is not set up, so the Pi is
      using the network cable" — overwriting "Connected to kentwa" with a flat
      contradiction. Blank now disambiguates on the saved network in
      `wpa_supplicant.conf`: with one, it reads "Wi-Fi is already set up for
      *ssid*… this file looks blank, that is normal and it means it worked".
      Deliberately not phrased as "connected": the applier runs before
      association, so a live connection there would be a guess.

- [x] **CRLF from a Windows editor silently broke the whole Wi-Fi path — fixed
      2026-07-29.** `x16-wifi.conf` was sourced straight off the card. The file
      exists *specifically* to be edited on a Windows PC, and an editor that
      saves CRLF leaves a trailing `\r` inside every value. Measured on the Pi:
      the SSID becomes `MyNetwork\r`, `wpa_passphrase` then dies with "Invalid
      passphrase character", and `wpa_supplicant.conf` is written with a header
      and **no network block** — so the Pi never associates, the card is never
      cleared, and the owner is told to check a password that was right all
      along. The country gate rejects `US\r` too and silently falls back.
      Now sources a CR-stripped copy, which keeps shell quoting working so
      `X16_WIFI_SSID="My Home Network"` still parses.
      **This one cannot be caught on a dev box:** git-bash/MSYS strips CR when
      sourcing, so the local test passed while the appliance failed. Reproduce
      shell-parsing bugs on the target, not on Windows.
      Same fix added a passphrase length gate (WPA needs 8–63 characters) —
      outside that range `wpa_passphrase` refuses and produced the same empty
      config and the same misleading "check your password".

- [x] **Two applier defects found by the Pi 4 boot test, both fixed
      2026-07-29** (in `scripts/x16-wifi-apply.sh`; the flashed card still runs
      the old copy, so they need a redeploy before the Wi-Fi hardware test):
      - **`x16-wifi-status.txt` was never created out of the box.** The blank-SSID
        path `exit 0`-ed before calling `status()`, so on the state every card
        ships in the file simply did not exist — while
        `dist/README-end-user.md` §6 and its troubleshooting table both tell the
        owner to go and read it. First instinct on a new card is to look, and
        finding nothing reads as a broken card. Now written on that path too, and
        `status()` is idempotent (previous body cached on ext4) so the steady
        state is still **zero** FAT writes per boot — which matters for an
        appliance switched off at the wall.
      - **The rfkill unblock never actually ran.** `rfkill` is not in the image —
        Bookworm ships it as its own package and DietPi does not pull it in — so
        the `command -v rfkill` guard was always false and silently skipped the
        unblock the script's own header calls mandatory on a Pi 3. Replaced with
        direct `/sys/class/rfkill/*/soft` writes: no package dependency, works on
        a card built offline, leaves Bluetooth alone, and logs a warning for a
        HARD block (whose symptom is otherwise identical to a wrong passphrase).
- [ ] Re-check [dist/README-end-user.md](dist/README-end-user.md) against the
      final image — especially the FAT drive's label and free space, which is the
      first thing an owner sees. `check-image.sh` prints both. The `bootfs` label
      claim was **wrong** and is corrected: try6's FAT has no volume label at all,
      so Windows shows a bare drive letter.
- [x] **FAT volume label SETTLED: `X16PI`, and it needed a new script
      (2026-07-30).** A named drive is a much better first impression than
      "Removable Disk (E:)", and `dist/README-end-user.md` now names it, so it is
      no longer cosmetic — the README would be telling the owner to look for a
      drive that doesn't exist.
      The catch: the only thing that ever set a label was `refit-fat.sh --label`,
      via `mkfs.vfat -n` — and the refit is **off by default** now that FAT stays
      at DietPi's stock 128 MB. So the label had no path to the shipped image at
      all. Fixed by [`scripts/release/set-fat-label.sh`](scripts/release/set-fat-label.sh),
      offline on the capture, wired into `make-release.ps1` (`-FatLabel`,
      defaulting to `X16PI`) after any refit; `refit-fat.sh`'s own default is
      `X16PI` too so a refit cannot strip it. `check-image.sh` **fails** an
      unlabelled image.
      Offline rather than on the Pi on purpose: `/boot/firmware` is mounted *and*
      bind-mounted into the running emulator's fsroot, so relabelling live means
      the kernel's cached boot sector can win on unmount and the change may not
      stick. `prep-image-source.sh` only reports the label, and says where it is
      actually applied.
      Verified against a synthetic 128 MB-FAT + ext4 MBR image in WSL: label set,
      **FAT volume serial unchanged** (`/etc/fstab` mounts `/boot/firmware` by it,
      so a changed serial would boot with no boot partition), MBR disk id
      unchanged, dirty bit from a live capture cleared first (`fatlabel` refuses
      on a dirty volume), idempotent on re-run, and over-long / illegal labels
      rejected rather than silently truncated.

- [x] **The appliance loop spun with no backoff when no display is attached —
      found 2026-07-30 by accident, fixed the same day.** The dev Pi was powered
      up with the TV off,
      and `custom.sh` had relaunched `x16emu` **626 times in 32 minutes**, one
      every ~3 s, for as long as it was left alone. Both connectors read
      `disconnected`, so `find_display` burns its full timeout (display ready at
      36.5 s instead of ~5 s), then `x16emu` exits `rc=255` with
      `SDL_Init failed: kmsdrm not available`, and the loop immediately tries
      again. Forever.
      This is the owner-facing case of "TV is off, or on the wrong input", so it
      is not an artificial condition. Nothing is corrupted — `/var/log` is a
      tmpfs, so the log spam never touches the card — but two things are wrong:
      it holds a core busy indefinitely, and at ~150 bytes a launch it will fill
      a 50 MB tmpfs in roughly a fortnight on a unit left switched on.
      **FIXED 2026-07-30** in [`scripts/custom.sh`](scripts/custom.sh): backoff of
      3 → 6 → 12 → 24 → 30 s and then 30 s forever, reset to instant the moment
      the emulator runs properly (so `pkill -x x16emu` from the SSH tool still
      applies a settings change with no visible delay). `noisy()` logs the first
      three attempts and then every twentieth, and a single plain-language line
      fires at attempt four saying the display is probably off — that log is the
      only diagnostic an owner with no shell can be talked through by phone.
      Deliberately never gives up.
      Verified under `dash` (the appliance runs `/bin/dash`, not bash) and then on
      the hardware in the genuine disconnected state: **66 attempts per 32 minutes
      instead of 626**, and 4 log lines per 150 s instead of ~50.
      One thing deliberately left unbounded: x16emu's own stderr is redirected into
      the log every attempt, so one `SDL_Init failed` line per retry still
      accumulates — ~115 KB/day at the 30 s cap, i.e. over a year against the
      50 MB tmpfs rather than a fortnight. Kept readable on purpose: if the failure
      reason ever changes, that line is the only evidence of it.
      Note this also means **`launch at N s` is not a valid boot metric unless a
      display is actually connected**: measure `systemd-analyze` and `read_wait`
      for card/boot work, and only trust
      `launch at` with the TV on.

- [x] **`/root` shipped the developer's working files — fixed in prep
      2026-07-30.** 2.2 MB of them on the dev Pi: `sdbench-*.txt` and `sdbench.sh`
      from the SD test, `oc100.log`, `config.txt.orig-presdtest`,
      `custom.sh.prev-backoff`, an orphaned `x16-wifi-apply.bak-20260729`,
      `x16-pull.tgz` / `x16scripts.tgz` staging archives, `install.log`, and the
      `x16-pull` / `x16-deploy` staging dirs. `prep-image-source.sh` only ever
      cleaned `/root/.bash_history` and the mesa shader cache, so all of it would
      have gone into the image.
      Deliberately a **named list**, not "empty `/root`": the dotfiles there are
      real (`.bashrc`, `.profile`, `.hushlogin`, `.ssh`) and wiping them would
      change how a shipped unit behaves. Anything unrecognised is **reported** for
      a human to judge rather than deleted — and that survey skips the patterns the
      cleanup handles, because otherwise a dry run flags all sixteen already-handled
      files as unknown, which is worse than no survey. Verified against the real
      mess: it now reports only `cleanup.sh`.

- [x] **`/root/.ssh/authorized_keys` ships 2 keys — DECIDED 2026-07-30: leave it.**
      Checked how the two mature comparison distros handle the same question:
      **neither Dosbian V1.0 nor Combian V3.0 ships an `authorized_keys` at all**,
      in `/root` or any home — they avoid the problem rather than manage it. Their
      *host* keys, though, are baked in exactly like ours (4 pairs, mtime one
      minute after `/etc/rpi-issue`, so pi-gen build-time and shared by every unit
      ever flashed), which makes our accepted risk there the normal position for
      this class of image rather than a corner cut.
      Also found, and worth remembering as a general lesson:
      `regenerate_ssh_host_keys.service` is present on both images with **no enable
      symlink anywhere**, and the unit ends in
      `ExecStartPost=/bin/systemctl disable regenerate_ssh_host_keys` — it ran once,
      disarmed itself, and got captured dead. That is the identical failure mode as
      DietPi's `dietpi-fs_partition_resize.service` which cost us a flash-and-fail
      cycle. **A self-disabling first-boot unit always ships disabled unless
      something re-arms it before capture** — two independent distros prove it.
      The nicer pattern, recorded but deliberately NOT adopted: Dosbian ships SSH
      *off*, with `sshswitch.service` gated on `ConditionPathExistsGlob=/boot/ssh{,.txt}`,
      so nothing listens until the owner drops a file on the FAT partition. Both
      distros also lock root, where we allow root over dropbear.
      Not doing it: dropbear here runs without `-R` so it needs host keys already
      present, which makes the ordering fiddly for no benefit on units that stay in
      the owner's hands.
      image can SSH into **every unit flashed from it**. Left in place on purpose,
      because deleting it is how you lock yourself out of your own machines — and
      SSH is how every fix in this project has been delivered.
      Note this is a *bigger* question than the shared dropbear host keys, which
      are already accepted: host keys let a unit be **impersonated**, this lets a
      unit be **entered**. `prep-image-source.sh` now prints the key count and says
      it left them alone, so the choice is made in the open at capture time rather
      than by default. Also still true: DietPi's root password is whatever it is on
      the build Pi.

## Phase 4 leftovers (subjective — need eyes on the TV)

- [ ] Cold-boot and confirm nothing flashes on screen before the splash: no
      kernel text, no cursor, no login line.
- [ ] Load something that scrolls and check for tearing / judder.

## Nice to have

## Boot speed — candidates from Combian V3.0 / Dosbian V1.0 (read 2026-07-29)

Read-only teardown of two mature Pi appliance distros on the NAS. Both are the
same author's, off one pi-gen Raspbian Buster stage2 base (Feb 2020) — even the
same disk id `0x738a4d67`, so treat them as one data point, not two.

**What the teardown actually showed.** Dosbian is *not* a trimmed system: `cron`,
`rsyslog`, `dhcpcd`, `wpa_supplicant`, `triggerhappy`, `nfs-client.target`,
`rpi-eeprom-update`, `rsync`, `apt-daily`, `man-db` and `logrotate` are all still
enabled, and its own menu offers "DISABLE DHCPCD: Speed up boot process" — they
knew it cost them and shipped a user toggle instead of a fix. Its speed is
largely **perceptual**: the splash paints in the first systemd transaction and is
then never overwritten, so no boot text is ever seen. We already do that; they
just protect the splash better. Our DietPi base is leaner than theirs.

Caveat for the morning: this is all read from configuration. Nothing below has
been booted or timed except where noted. Item 1 is the only one with a hardware
effect; the rest are correctness/robustness wins that may cost nothing.

- [x] **1. SD clock overclock — TESTED 2026-07-30, and it CANNOT WORK ON A PI 4.
      Reverted.** Two things were wrong with the plan, and the second one is the
      real answer.

      **The syntax is obsolete.** `dtoverlay=sdtweak,overclock_50=100` would have
      done nothing quietly: this firmware's own `overlays/README` says
      `Name: sdtweak / Info: This overlay is now deprecated. Use the sd_* dtparams
      in the base DTB / Load: <Deprecated>`, and `sdtweak.dtbo` is not even
      shipped on the image. The live form is `dtparam=sd_overclock=100`. (DietPi
      already uses the modern spelling elsewhere — `dtparam=sd_poll_once`.)

      **The knob does not reach the Pi 4's card.** Applied
      `dtparam=sd_overclock=100`, rebooted, and the bus clock did not move:
      `/sys/kernel/debug/mmc0/ios` read `50000000 Hz` before and after, and boot
      was identical to the millisecond in userspace (1.699 s + 15.317 s baseline
      vs 1.706 s + 15.317 s). The device tree says why — the firmware wrote the
      property onto a **disabled** node:

      | node | status | `brcm,overclock-50` |
      | --- | --- | --- |
      | `/soc/mmc@7e202000` | **disabled** | **100** ← where the dtparam landed |
      | `/soc/mmcnr@7e300000` (mmc1 = SDIO/Wi-Fi) | okay | 0 |
      | `/emmc2bus/mmc@7e340000` (mmc0 = **the SD card**) | okay | *no such property* |

      On a Pi 4 the card is on the `brcm,bcm2711-emmc2` controller, whose node
      exposes **no overclock property at all**. `sd_overclock` targets the old
      bcm2835 controllers, which on this board are either disabled or driving the
      Wi-Fi SDIO chip. Worth checking that it did *not* leak onto Wi-Fi — it
      didn't, `mmcnr` stayed 0.
      No corruption: zero `mmc0` CRC/timeout lines, zero `EXT4-fs error`, FS
      clean. (A p1 sha256 did change between runs — that was our own `config.txt`
      edit, since config.txt lives on p1. Not evidence of anything.)

      **On a Pi 3 it probably DOES apply**, because there the card sits on one of
      the bcm2835 controllers this dtparam actually targets. So this is a
      **Pi-3-only** lever, not the "all Pi models" one the note assumed — and
      since we ship ONE image for both, enabling it means overclocking the Pi 3's
      card on every unit. Test it deliberately during the Pi 3 leg, from a clean
      Pi 3 baseline, with [`scripts/x16-sdbench.sh`](scripts/x16-sdbench.sh).
      **Moot for a Pi-4-only release** — nothing to do.

- [ ] **1a. The card IS the bottleneck — so buy a better card, don't overclock a
      bad one.** This is what the measurement actually found, and it is the
      biggest boot-speed lever left. On a clean boot the Pi 4 spends
      **15.2–15.6 s of a 17.0 s boot waiting on card reads** (`read_wait` from
      `/sys/block/mmcblk0/stat`, 95.8 MB read, 2 253 reads). Not CPU, not
      services — the card.
      And the dev card is a **Samsung dated 07/2011**: SD High Speed only, 3.3 V
      signalling, UHS speed grade 0 in its SSR, measuring **21.4 MB/s sequential
      and 5.0 MB/s on 4 K reads** — and 4 K random is what boot actually pays.
      A modern UHS-I A1/A2 card would negotiate 1.8 V SDR104 on the Pi 4's emmc2
      controller instead of topping out at 50 MHz High Speed, and A1 guarantees
      an order of magnitude more random IOPS. That needs no config change and
      carries no overclock risk.
      Do NOT quote a predicted saving — `read_wait` overlaps with CPU work, so it
      is an upper bound, not a subtraction. Measure it: same image, same
      procedure, modern card, compare `systemd-analyze` + `read_wait`.
      Method note learned here: **within one boot the sequential figure is stable
      to ±1 %, but across boots it moves ~5 %.** So compare across-boot numbers
      only against across-boot noise, and never call a 5 % change a result.

- [x] **2. `console=tty3` — ADOPTED 2026-07-30, but the reason above was WRONG and
      it is not what fixes anything.** Adopted because it does move `/dev/console`
      off the visible VT (`/sys/class/tty/console/active` reads `tty3`), so
      userspace writers land on a VT nobody looks at. Costs nothing: launch at
      6.65 s against a 6.56 s baseline.
      **The claim it would keep KERNEL messages off the screen is false.** The
      kernel's VT console writes printk to `fg_console` — the *foreground* VT —
      whatever `ttyN` you name in `console=`. Proved by reading the VT text buffers
      directly: with `console=tty3` live and `printk: legacy console [tty3] enabled`
      in dmesg, an injected `KERN_ERR` appeared in **`/dev/vcs1`** and `/dev/vcs3`
      was **empty**. The "switch to VT3 and read the boot log" diagnostic benefit
      does not hold either, for the same reason.
      Reading `/dev/vcsN` is the technique to remember here — it shows exactly what
      is on a VT, so this class of question never needs someone at the TV again.

- [x] **2a. What ACTUALLY keeps kernel messages off the X16 — a third DietPi
      double-switch (2026-07-30).** `/etc/sysctl.d/97-dietpi.conf` sets
      `kernel.printk = 4 4 1 7`, systemd-sysctl applies it after boot, and it beats
      the kernel command line: cmdline said `quiet loglevel=1` and
      `/proc/sys/kernel/printk` still read **4**. At console level 4 any `KERN_ERR`
      is printed to the foreground VT, and printing to a VT makes fbcon repaint the
      console **over** whatever x16emu is showing.
      That is a real, owner-visible defect, not a theoretical one. The trigger
      found in the wild: `brcmf_cfg80211_reg_notifier: Firmware rejected country
      setting`, fired at **9.06 s — 2.5 s after the emulator was already running** —
      whenever Wi-Fi associates with an AP whose beacon advertises a different
      regulatory domain than the configured one. Ordinary network, no fault, and no
      country setting of ours prevents it: the AP wins and the firmware refuses the
      change the AP asks for. `GB` was tried and does not silence it.
      Fixed by [`config/98-x16-console.conf`](config/98-x16-console.conf) —
      `kernel.printk = 1 4 1 7`, numbered **98 so it sorts after DietPi's 97**.
      Renumbering it below 97 silently disables it. `KERN_EMERG` still prints,
      which is correct — a panic *should* be allowed over the emulator — and the
      ring buffer and journal are untouched, so `dmesg` still shows everything.
      Verified across a full reboot: console loglevel 1 from boot, the message
      still fires at 9.54 s and is still in `dmesg`, and **`/dev/vcs1` is empty**.
      Installed by `trim-boot.sh` (and removed by its `--revert`); `check-image.sh`
      **fails** an image without it, and notes any lower-numbered file that also
      sets `kernel.printk`.
      **Third instance of the same pattern** — after `dtoverlay=disable-wifi` +
      module blacklist, and the serial console unit + `dietpi.txt` — so it is now a
      rule, not a coincidence: *when DietPi appears to ignore a setting, look for
      DietPi's own copy of it somewhere else.*

- [x] **3. `TTYVTDisallocate=no` — ADOPTED 2026-07-30, and the suspicion was
      right.** `getty@.service` ships `TTYVTDisallocate=yes` and its own comment
      says "the VT is cleared by TTYVTDisallocate". Timestamps on the dev Pi:
      `x16-splash.service` finished painting at **4.941 s**, `getty@tty1` started at
      **5.280 s** — so the splash already on screen was thrown away 0.34 s later,
      which is why `custom.sh` paints a third time. Both comparison images set this
      to `no` in a drop-in they call `noclear.conf`.
      Installed by `trim-boot.sh` as `20-keep-vt.conf`. Costs nothing measurable:
      launch at 6.53 s with it, 6.56 s without.
      It does **not** remove the `custom.sh` paint, though, so we did not lose a
      moving part: that paint also provides the `X16_SPLASH_SECONDS` hold, which is
      what makes the splash visible at all before the emulator's modeset covers it.

- [x] **4. Initramfs — we do not ship one. Nothing to do.** No `initramfs*` or
      `initrd*` on the boot partition, no `initramfs` directive in `config.txt`, no
      `initrd` token in `cmdline.txt`, and `systemd-analyze` reports only
      `(kernel) + (userspace)` with **no initrd phase**. Same as both comparison
      images. `initramfs-tools` is installed as a package but nothing generates or
      loads an image, and on a Pi the firmware only loads one if `config.txt` names
      it. Useful negative result: the ~1.7 s kernel time is genuinely kernel, so
      there is no hidden initrd time to reclaim.

**Explicitly rejected — do not re-litigate:**

- `elevator=deadline` (in both images): dead parameter on blk-mq kernels.
- `fbi` for the splash: ours is better — pre-rendered RGB565 straight to
  `/dev/fb0`, no package, no resident process. Theirs does auto-handle any
  resolution where we ship three blobs and pick by framebuffer size; that is a
  robustness edge, not a speed one, and not worth the dependency.
- Their service set: we are already leaner.
- `disable_splash=1`: they suppress the rainbow because their branded splash
  arrives early enough to replace it. We chose `disable_splash=0` on purpose so
  something appears at ~1 s. A real fork in the design, not an oversight.

## Boot time — DONE 2026-07-25 (x16emu launch 13.1 s → 6.2 s since kernel start)

Owner-reported wall clock, power-on to `READY.`: **39 s → 30 s** before the last
two fixes below; expect roughly 23 s after. The gap between "6 s since kernel
start" and the stopwatch is firmware/EEPROM before the kernel plus the TV's own
sync/input-switch delay — neither is ours to fix, and the TV is likely the
larger of the two.

Instrumented timeline (`/var/log/x16-appliance.log`, seconds since kernel start):
`getty@tty1` 3.2 → `custom.sh` entered 5.0 → display ready 5.1 → launch 6.2.

All fixes applied on the dev Pi and captured in
[`scripts/trim-boot.sh`](scripts/trim-boot.sh) (idempotent, `--revert`
supported). **Must be run when building the image.**

- [x] `getty@tty1` no longer ordered behind `network.target`. It was waiting for
      `ifup@eth0` → the router's `DHCPOFFER`, 7.9–14.9 s with the Pi idle.
      `getty@tty1` now starts at **3.3 s** (was 20.3 s).
- [x] `serial-getty@ttyS0` disabled + `console=ttyS0` dropped from `cmdline.txt`.
      It had been waiting out a 90 s device timeout every boot, so
      `multi-user.target` didn't activate until 92.9 s. Total boot is now ~16 s
      instead of ~93 s, and nothing blocks the X16.
- [x] **`getty@tty1` `Type=idle` removed — a flat 5 s.** systemd holds an idle
      unit's `ExecStart` until the job queue drains or 5 s pass, so a login
      prompt doesn't interleave with boot messages. tty1 here is the emulator,
      not a prompt (`agetty -l custom.sh`), and the queue never drains early
      because DHCP runs to ~14 s — so it always paid the full 5 s. Found only
      after instrumenting `custom.sh`: the unit was active at 3.2 s but the
      script wasn't entered until 9.9 s.
- [x] `X16_SPLASH_SECONDS` 3 → 1.

- [x] **Splash now paints at 2.68 s instead of 4.78 s** via
      `config/x16-splash-early.service`. The Pi firmware hands the kernel a
      `simple-framebuffer` at 0.7 s whose format (`r5g6b5`, 1920x1080, stride
      3840) is byte-identical to the KMS console's, so the existing blob can be
      written to it with no conversion — no need to wait for vc4 at 4.3 s.
      Both splash units are kept: the KMS handover blanks the console
      (`switching to colour dummy device` at ~4.35 s), and `x16-splash.service`
      repaints at ~4.8 s. Brief ~0.45 s blank there — worth an eyeball.

Remaining, optional:

- [ ] ~1.7 s still passes between `getty@tty1` activating (3.2 s) and `custom.sh`
      being entered (5.1 s) — agetty startup. Probably where a dedicated
      `x16.service` would help, but it steps outside `dietpi-autostart`, which is
      DietPi's supported mechanism. Small, and the big wins are banked.
- [ ] ~2.7 s is the practical floor for the splash: systemd only takes over at
      ~1.7 s and the unit has no ordering left to drop. Earlier would have to
      come from the firmware, which supports no custom image — its only boot
      visual is the rainbow test pattern (`disable_splash=0`), currently off.
- [ ] Cheap trims: `rpi-eeprom-update` 688 ms, `keyboard-setup` 302 ms, FAT
      `systemd-fsck` 435 ms. Kernel is 1.66 s, so ~3 s is close to the floor.
- [ ] **Static IP is not needed for boot speed** and should NOT ship in the
      image (unknown network, collision risk). DHCP now finishes in the
      background, ~14 s after the X16 is already up. If a stable address is
      wanted on a dev unit, prefer a DHCP reservation on the router over editing
      `/etc/network/interfaces` — no pool collision, survives re-imaging, and no
      risk of locking yourself out of a headless Pi.
- [x] **`x16-wifi-apply` tested against a real AP (2026-07-25) — and it did not
      work first time.** Two bugs, both fixed and re-verified from a clean
      "owner" state (radio disabled, `allow-hotplug` commented, no stamp):
      the applier now un-comments `allow-hotplug wlan0` (DietPi comments it out
      when Wi-Fi is disabled, so the radio came up but nothing ever launched
      `wpa_supplicant`), and it writes the per-interface
      `wpa_supplicant-<iface>.conf` that systemd's template unit actually reads.
      The old code's `systemctl restart wpa_supplicant@wlan0` reported *success*
      for a unit that died 260 ms later, so the `ifup` fallback never ran.
      Result: associates unaided at boot, DHCP lease, routes to the internet,
      and the emulator still launches at 6.6 s.
- [x] Moot — Pi 4 only. ~~Still untested on a **Pi 3**~~ — different Wi-Fi chip (BCM43438 / BCM43455
      vs the Pi 4's) and slower firmware load, so the "interface appeared after
      Ns" path may behave differently.

## Pi 3 test — MOOT (release narrowed to Pi 4 only, 2026-07-30)

Nothing in this section is outstanding. The prep work described here was done and
is harmless to keep — the 720p / 640x480 splash blobs and the non-HDMI display
detection also cover a Pi 4 on an awkward TV or a DPI hat, so none of it was
removed. The hardware run never happened, which is exactly why the Pi 3 is **not**
a supported target.

Two things that would have failed silently on the bench are fixed already:

- [x] **Splash blobs for 720p and 640x480.** `x16-splash` skips a blob whose
      size doesn't match the framebuffer (drawing it would garble the screen),
      so a Pi 3 at 720p, or on a VGA HAT at 640x480, would simply have shown
      black with nothing in any log. All three sizes now selected automatically
      by framebuffer geometry; regenerate with
      [`tools/make-splash-assets.sh`](tools/make-splash-assets.sh). Selection
      verified against injected geometries for 1080p / 720p / 480p, plus the
      two safe-skip cases (unknown size, 32bpp).
- [x] **`custom.sh` no longer waits specifically for HDMI.** A VGA HAT drives
      DPI and presents no HDMI connector at all, so the old `find_hdmi` would
      have burned the full 30 s timeout on *every* boot before starting the
      emulator. `find_display` still prefers HDMI, accepts any connected
      connector, and skips Writeback. EDID forcing is now HDMI-only — DPI has
      no EDID to override.

Still to do on the hardware itself:

- [ ] Pi 3B/3B+, micro-USB 2.5 A PSU (not USB-C), full-size HDMI (not micro).
      Keep Ethernet plugged in throughout — every fix this week came via SSH.
- [ ] Run `scripts/trim-boot.sh`, but **check `serial-getty` first**: on a Pi 3
      `ttyS0` may be a genuine console rather than the not-ready mini-UART it is
      on the Pi 4. The script tests udev readiness rather than existence, so it
      should do the right thing — confirm that it does.
- [ ] Decide 1080p vs 720p by eye (`hdmi_mode=4`, `X16_OUTPUT=720p`,
      `x16-720p.edid`), then re-check HDMI **audio** — it has broken silently
      once already when the mode changed.
- [ ] VGA HAT path: `X16_FORCE_EDID=0`, and confirm the appliance starts
      promptly rather than after a 30 s wait (the fix above).
- [ ] Fold this into the Phase 5 gate — DOC/07 already requires flashing the
      shrunk image to a blank card and booting a *second* Pi. Doing that on the
      Pi 3 covers both jobs and tests the "single arm64 image for both models"
      claim the whole design rests on.
- [ ] Untested: an AP that is genuinely absent or has a wrong passphrase now
      that the apply path works. The "keep the stamp, let wpa_supplicant retry"
      design has never been exercised against a real failure.
- [ ] Consider bundling `x16-gamepad-test` and `x16-wifi` into the shipped image,
      or leaving them as repo-only service tools.
- [ ] `/usr/local/bin/x16-esc-test` exists on the dev Pi but is not in the repo —
      decide whether it's worth keeping.

## Watch out for (bitten by these already)

- **A systemd drop-in cannot remove an ordering dependency.** `After=` (empty)
  resets the unit's own list, but systemd already registered the mirrored
  `Before=` edge on the other unit while parsing, and that survives. Verified
  here: the drop-in loaded correctly and changed nothing across a full reboot.
  Use a full unit override in `/etc/systemd/system/` so the line is never parsed.

- Anything writing `x16.conf` must round-trip **every** key; `x16-display`
  rewrites the file wholesale and silently dropped settings until
  `smoke-test.sh` grew a guard for it.
- Forced-EDID changes: verify with `cat /sys/module/drm/parameters/edid_firmware`
  and the connector's `modes` list, and re-check **audio** afterwards. Both have
  failed silently before ([DOC/08](DOC/08-display-fixes.md)).
- Wi-Fi credentials do nothing while `dtoverlay=disable-wifi` is present. Use
  `x16-wifi`, which refuses to pretend otherwise.
