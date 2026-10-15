# Changelog

CI uses the section matching the build's version as the GitHub Release notes and as the
"What's New" text in Settings › Software Update. Keep the heading format `## X.Y.Z`.

## 0.5.0

- **Playback speed:** a speed button in Now Playing opens a draggable bar from 0.5× to 2×. It snaps to 0.5, 0.75, 1, 1.5 and 2 and stops anywhere in between; pitch stays natural. Speed persists between launches.
- **Software Update:** Install Update now opens the install page and starts the iOS install prompt straight away, instead of trying an in-app install that iOS blocks.
- **Removed Discord status.** Any saved Discord token is deleted from the Keychain on first launch.

## 0.4.0

### Library and playback
- **Playlists:** a new Playlists view in the Library. Create, rename, reorder and delete playlists, add songs from any song menu or selection, and import or export `.m3u8` files. Favorite Songs and Most Played are built in.
- **Parametric EQ:** the Equalizer now has a Parametric mode with up to 16 bands (peak, shelves, low/high pass) with free frequency, gain and Q, a real frequency-response curve and an Auto preamp to avoid clipping.
- **AutoEQ profiles:** search your headphones or IEMs and load their correction profile in one tap. Equalizer APO text can be pasted in or copied out.
- **Bit-perfect mode:** for USB DACs. Switches the output to each song's sample rate and skips the EQ and volume processing. Now Playing shows when it's achieved, or why not.
- **Lyrics files:** a `.lrc` next to a song is used before LRCLIB. Import one from a song's menu or the lyrics screen; album downloads also fetch any `.lrc` files from the peer.
- **Custom artwork:** change an album's or song's cover from Photos or Files, and switch back to the original.

### Transfers
- **Bulk download management:** select multiple downloads to retry, cancel, clear or delete the files, plus Retry All Failed, Clear Completed and Clear Failed.
- **Wi-Fi Transfer:** open the address shown in Settings on a computer on the same network to drop in music or download files, protected by an access code.
- **Seeding Mode:** keeps colon3 online in the background so people can keep downloading from you, and reconnects if Soulseek drops.
- **Dynamic Island:** transfer progress now climbs across the whole batch instead of resetting after each file, and tapping the island opens Downloads.

### App
- **Stats:** listening time, a daily chart, top songs, artists and albums, and Soulseek upload/download totals with your share ratio.
- **Software Update:** Settings shows when a newer build is published and installs it in place, with Stable and Beta channels.
- **Diagnostics & Logs:** a live session log and crash reports you can view and share from Settings.
- **Discord status:** optional "Listening to colon3" on your Discord profile, set up by logging in to Discord in the app. Uses your account token, which is against Discord's Terms of Service.
- **Links:** `colon3://player`, `colon3://downloads`, `colon3://library`, `colon3://search?q=…` and `colon3://wifi` for Shortcuts and Back Tap.
