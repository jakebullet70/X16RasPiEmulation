# Commander X16 — Raspberry Pi Edition

This SD card image turns a Raspberry Pi into a **Commander X16**. Switch it on and
the X16 is there, fullscreen on your TV. Switch it off at the wall when you're
done — there's nothing to shut down.

You need: a **Raspberry Pi 3 or 4**, a micro-SD card (8 GB or larger), an HDMI
cable, a USB keyboard, and a USB power supply.

---

## 1. Put the image on the SD card

1. Install **Raspberry Pi Imager** from <https://www.raspberrypi.com/software/>.
2. Open it, click **Choose OS** → scroll to the bottom → **Use custom image**.
3. Pick the file `x16-appliance-r49.img.gz`.
4. Click **Choose Storage**, select your SD card, then **Write**.
   If it offers to apply customisation settings, choose **No** — this image is
   already set up.

This erases everything on the card, so use a blank one or a card you don't mind
wiping.

## 2. First switch-on

Put the card in the Pi, plug in the HDMI cable and the keyboard, then plug in the
power.

The first boot takes about a minute longer than usual — the system is expanding
to fill your card. That happens once. After a black screen and a splash you'll
see the Commander X16 `READY.` prompt, and you can type straight away.

Every boot after that goes straight to the X16.

## 3. Add your own programs

The card holds a folder your X16 can read, and you fill it from your computer.

1. Unplug the Pi's power.
2. Take the SD card out and put it in your computer.
3. A small drive appears (Windows may call it `bootfs`). **Ignore any message
   offering to format the card — click cancel.** Windows can only see this one
   small drive; that's normal.
4. Open the **`x16`** folder on it and copy your `.PRG` and `.BAS` files in.
5. Eject the card properly, put it back in the Pi, and power on.

Then, at the X16 prompt:

```text
DIR                 (lists your files)
LOAD"FILENAME"      (loads one — the quotes matter)
RUN                 (starts it)
```

That drive is small — around 100 MB — so it holds a good personal selection
rather than an entire collection. If you fill it, just swap files in and out.

## 4. Sound and controllers

Sound comes out of the **HDMI display**, so it plays through your TV's speakers.
Turn the TV volume up if you hear nothing.

For a **USB gamepad**, plug it in *before* switching the Pi on. Common controllers
are recognised automatically and act as the X16's joystick.

## 5. Changing how the picture looks

The image ships set to fill a widescreen TV. To change that, put the SD card in
your computer and open the file **`x16.conf`** on the same small drive, using any
plain text editor (Notepad is fine). The comments inside explain each setting —
the useful ones are:

- `X16_DISPLAY` — `widescreen` fills a 16:9 TV; `authentic` gives the true 4:3
  shape with black bars at the sides.
- `X16_SCALE` — how large the picture is drawn.
- `X16_OUTPUT` — `1080p` or `720p`.
- `X16_JOYSTICKS` — how many gamepads to accept, `0` to `4`.

Save the file, eject, and boot the Pi to see the change.

## 6. Connecting to Wi-Fi (optional)

The Pi uses a network cable out of the box. To use Wi-Fi instead, you don't need
a keyboard or any commands — just edit a file on the card:

1. Power the Pi off and put the SD card in your computer.
2. Open **`x16-wifi.conf`** on the small drive that appears, in any plain text
   editor (Notepad is fine).
3. Fill in your network name and password, and set your country:

   ```text
   X16_WIFI_SSID=YourNetworkName
   X16_WIFI_PSK=YourPassword
   X16_WIFI_COUNTRY=GB
   ```

4. Save, eject the card, put it back in the Pi, and power on.

The Pi applies the settings itself. **The first time you do this it restarts once
on its own** — switching the radio on needs a restart — so give it an extra
minute before assuming something is wrong.

Notes:

- The country code is required. Wi-Fi is regulated per country and the Pi won't
  transmit properly until it knows where it is. `GB`, `US`, `DE`, `FR`, `AU`, …
- The network name is case-sensitive.
- The password sits in a plain text file that any PC can read, so don't use this
  on a network whose password you'd mind sharing.
- If it doesn't connect, the reason is written to `/var/log/x16-appliance.log`
  on the Pi — usually a wrong password or the wrong country code.

## 7. Adding programs over your network (optional)

If you'd rather not keep taking the card out, the Pi can share the folder over
your home network. Run this once, with the Pi connected by Ethernet or Wi-Fi:

```bash
sudo ~/scripts/setup-samba.sh
```

Then on a PC open `\\<pi-address>\X16` and drag files in. The login is `dietpi`
with password `dietpi` — the stock defaults, fine on a home network, but change
them (`passwd`, then `smbpasswd -a dietpi`) if your network isn't private.

To reach the Pi's command line at all, connect with SSH as `root`, password
`dietpi`.

## 8. If something's wrong

| What you see | What to try |
| --- | --- |
| Nothing on screen | Check the TV is on the right HDMI input. Try the Pi's other HDMI port (Pi 4 — use the one nearest the power socket). Try a different HDMI cable. |
| Screen stays black after the splash | Some TVs need a moment — give it 30 seconds. If it's still black, set `X16_OUTPUT=720p` in `x16.conf` (see section 5). |
| No sound | Turn up the TV. Sound only comes out of the HDMI display, not the Pi's headphone socket. |
| Keyboard does nothing | Use a plain wired USB keyboard for the first test; some wireless dongles need a moment after power-on. |
| Gamepad does nothing | Plug it in before switching on. If it's still ignored, check `X16_JOYSTICKS` is not `0` in `x16.conf` (section 5). Unusual controllers may simply not be recognised. |
| `DIR` doesn't show my files | They must be inside the `x16` folder on the small drive, not loose at its top level. Check the filenames end in `.PRG` or `.BAS`. |
| It won't start at all | Re-flash the image (section 1). If that fails too, the SD card may be worn out — they do wear out. Try another card. |
| Wi-Fi won't connect | Check the network name's spelling and capitals, and that `X16_WIFI_COUNTRY` is your country (section 6). Remember the Pi restarts itself once the first time you enable Wi-Fi. |

## About this image

- Emulator: **x16-emulator r49**, with the matching **x16-rom r49**.
- The Commander X16 is David "the 8-Bit Guy" Murray's project; the emulator and
  ROM are made by the X16Community developers. This image just packages them to
  boot on a Raspberry Pi.
- The X16 moves forward over time. This image is **not** updated in place — when
  a newer X16 release is packaged, you flash a new image the same way you flashed
  this one. Your programs are on the card's small drive, so copy that `x16`
  folder to your computer first if you want to keep it.

Have fun. `READY.`
