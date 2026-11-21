# BRAW Preview

Finder thumbnails and Quick Look playback for **Blackmagic RAW (`.braw`)** clips on macOS.

> **Unofficial.** This is an independent open-source project. It is not made, endorsed or
> supported by Blackmagic Design. "Blackmagic RAW" is a trademark of Blackmagic Design Pty. Ltd.

- **Thumbnails** in Finder's icon, list, column and gallery views (a frame about one second in).
- **Playback with the Space bar**: in the Quick Look window the clip starts right away, with
  sound, looping. Click the picture (or ▶︎) to pause or resume; drag the bar to scrub. A sharper
  still appears while paused. In Finder's narrow preview pane it stays a still until clicked.
- **Look** (the same for thumbnails and playback):
  - a LUT the camera embedded in the clip is used as is;
  - otherwise log footage (Blackmagic Design Film) is shown as Extended Video in Rec.709, the way
    the camera's monitor shows it;
  - anything else (Video, Extended Video, custom curves) is shown as it was shot.

  The player's top line says which one applies (e.g. `LUT: …` or `Film → Extended Video`).

## Requirements

| | |
|---|---|
| macOS | 12 Monterey or later (Apple silicon and Intel) |
| **Blackmagic RAW** | free from Blackmagic Design: <https://www.blackmagicdesign.com/products/blackmagicraw> – it includes the Player and the SDK used for decoding |
| Xcode Command Line Tools | the installer offers to install them if missing (a few minutes) |

## Install

1. Install the **Blackmagic RAW** package, if you haven't already.
2. In Terminal:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/ranczandras/BRAW_thumbnail/main/get.sh | bash
   ```

That's it. The installer builds the app on your Mac, installs it as
`/Applications/BRAW Preview.app`, registers the Quick Look extensions, clears old cached
thumbnails, and opens the app once to confirm it's working.

<details>
<summary>Installing from a downloaded copy instead</summary>

Download this repository (green **Code** button → **Download ZIP**) and unzip it, or
`git clone https://github.com/ranczandras/BRAW_thumbnail.git`. Then in Terminal:

```bash
cd ~/Downloads/BRAW_thumbnail-main
```

```bash
bash install.sh
```

</details>

### Starts automatically

There is nothing to set up: BRAW Preview is **not a background app**. macOS starts its Quick Look
extensions by itself whenever Finder needs a thumbnail or a preview, and stops them afterwards.
It keeps working after a restart, without a login item.

To check or switch it on/off: **System Settings → General → Login Items & Extensions → Quick
Look** (on older macOS: System Settings → Extensions → Quick Look).

### Updating

Run the install command again after updating Blackmagic RAW (newer cameras need a newer SDK) or
when this repository has a new version.

### Uninstalling

```bash
curl -fsSL https://raw.githubusercontent.com/ranczandras/BRAW_thumbnail/main/uninstall.sh | bash
```

(or `bash uninstall.sh` from a downloaded copy)

## Thumbnails don't show up?

1. Close the Finder window and open it again (Finder caches the icons it has already shown).
2. Run the diagnostics with one of your clips:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/ranczandras/BRAW_thumbnail/main/scripts/doctor.sh | bash -s -- /path/to/clip.braw
   ```

   It shows whether the extensions are registered and enabled (`+`), which file type macOS gives
   the clip (it should be `com.blackmagic-design.braw-movie`), generates a test thumbnail, and
   prints the decoder's log.
3. If something looks wrong, open an issue with that output.

## How it works

- `BRAW Preview.app` is a small host app carrying two Quick Look extensions:
  `BRAWThumbnail.appex` (`QLThumbnailProvider`) and `BRAWPreview.appex` (a view-based Quick Look
  preview with its own player).
- Frames are decoded with the Blackmagic RAW SDK on the CPU, at the reduced resolution (1/8,
  1/4, 1/2) that fits the size needed, so a thumbnail takes a fraction of a second.
- During playback frames are decoded just in time (1/4 resolution for 6K, 1/8 for 12K), and the
  clock is the clip's own sound, so picture and sound stay in sync. When the Mac can't keep up,
  the player decodes smaller by itself and drops frames rather than falling behind.
- `BlackmagicRawAPI.framework` is copied into the extensions from the Blackmagic RAW installed on
  your Mac at install time: this repository neither contains nor distributes it. The app is
  compiled against the headers of that same SDK, so the versions always match.
- The app is built and signed (ad-hoc) on your own Mac, so no Apple developer account is needed
  and Gatekeeper doesn't block it.
- Quick Look extensions run sandboxed, so they can't read the `.sidecar` file next to a clip:
  adjustments saved there (ISO, white balance, a sidecar LUT…) are not applied; the camera's
  settings recorded in the clip are.
- Only the first two audio channels are played (cameras record the main pair there).

### Development

`scripts/build.sh [output-folder]` only builds, without installing. On every push, GitHub Actions
compiles the project on macOS against two versions of the SDK headers (SDK 4/5 and SDK 6).

## License

MIT – see [LICENSE](LICENSE). The Blackmagic RAW SDK belongs to Blackmagic Design and comes with
its own license.
