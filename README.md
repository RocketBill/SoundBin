# SoundBin

A fast, native sample browser for macOS. Point it at a folder of sounds and see every file as a waveform tile. Click one to hear it.

SoundBin is built for producers and sound designers with big sample libraries: thousands of files, nested folders, and no patience for opening them one at a time.

## Features

- **Waveform grid.** Every sound is a tile showing its waveform, name, length and format. Drag the toolbar slider or press ⌘+ / ⌘− to resize the tiles.
- **Instant playback.** Click a tile to play it, or move through them with the arrow keys and hear each one as you go. Space plays or stops, and ⌘L toggles looping.
- **Subfolders.** Include subfolders (on by default) to see a whole library at once, grouped into sections by folder.
- **Favourites.** Star the sounds you keep coming back to and find them all in one place, wherever they live on disk.
- **Search and sort.** Filter by name, and sort by name, duration, date modified, size or format.
- **Artwork.** MP3s, M4As and other files with embedded cover art can show it on their tiles.
- **Drag out.** Drag tiles straight into your DAW, Finder or anywhere else that accepts audio files.
- **Stays up to date.** Folders are watched, so new and deleted files show up automatically.
- **Quick to reopen.** Waveforms and artwork are cached, so folders open instantly next time.
- **Automatic updates.** SoundBin checks for new versions daily and offers to install them. You can turn this off, or have updates install themselves, in Settings.

SoundBin plays anything macOS can decode, including WAV, AIFF, MP3, M4A/AAC, ALAC, FLAC and CAF.

## Requirements

- macOS 26 or later

## Building from source

1. Clone the repo:
   ```sh
   git clone https://github.com/RocketBill/SoundBin.git
   ```
2. Open `SoundBin.xcodeproj` in Xcode 26 or later.
3. In the SoundBin target's **Signing & Capabilities** tab, choose your own team.
4. Build and run (⌘R).

The only dependency is [Sparkle](https://sparkle-project.org), for updates, which Xcode fetches automatically through Swift Package Manager.

## Releasing

`Tools/release.sh` builds a release, signs it with Developer ID, notarizes it and publishes it as a GitHub release, along with the signed Sparkle feed that existing copies check for updates. The setup it needs, and how to bump versions, is described at the top of the script.

## Privacy

SoundBin runs in the App Sandbox with read-only access to the folders you choose. It never modifies, moves or uploads your files. Its only network connection is the daily update check against this repository's GitHub releases, which you can turn off in Settings. The app itself has no network access: Sparkle's sandboxed helper does the downloading.

## Licence

SoundBin is free and open source under the [MIT Licence](LICENSE).
