# Changelog

CI uses the section matching the build's version as the GitHub Release notes and as the
"What's New" text in Settings › Software Update. Keep the heading format `## X.Y.Z`.

## 1.2.0

### New
- **Home:** a new first tab laid out like Apple Music, with shelves for **Trending Songs** (new songs climbing Apple Music's chart), the **Top 100**, **Recent Releases** and **Recently Played**, for any country. Songs you have play with a tap; the rest have a download button that finds them on Soulseek. A release opens its full tracklist with a tick on the songs you have: download missing songs one by one or all at once, or search Soulseek for the whole album. Reorder or hide the shelves in Settings › Home Sections.
- **Import from YouTube Music:** paste a link to any public or unlisted playlist from YouTube Music or YouTube; no account or setup. Songs are matched and downloaded the same way as Spotify and Apple Music imports.
- **Backup to Google Drive:** Settings › Backup saves your song list, playlists, favourites, listening stats and settings to a "colon3 Backup" folder in your Google Drive, now or automatically once a day. Turn on **Include Music** to upload the songs too (only new ones each time). Restoring brings everything back; songs that aren't on the phone can be downloaded from Drive or found again on Soulseek, and fill their playlists as they arrive. colon3 can only see the files it creates in your Drive. Passwords and keys are never backed up.
- **Backup files:** export the same backup as a file and import it on any phone, no Google account needed.

### Fixed
- **Non-square covers:** wide or tall album art (like a photo of a CD and its case) is now shown whole on a square, with a blurred copy of itself filling the sides, everywhere including the Lock Screen. Before, it was cropped, and in Now Playing it pushed the title and controls off the edges of the screen.

### Changed
- **Software Update:** the update button now opens the release on GitHub (the latest release on Stable, the releases list on Beta). The over-the-air install page is still there as a second button.

## 1.0.0

### New
- **Autoplay:** when the queue runs out, the music keeps going with songs similar to what you played, picked through Last.fm (needs a Last.fm API key). Songs in your library play straight away. Songs you don't have show under Up Next with a Download button: confirm it and colon3 finds the song on Soulseek, saves it to a "Found by Autoplay" playlist, and plays it once it's ready. Without Last.fm it plays more by the same artist, your most played, or anything else. Recently played songs are skipped. On by default; turn it off in Settings › Playback or with the ∞ button in the queue. **Only from Library** never suggests downloads, and **Download Suggestions Automatically** skips the button.
- **Import from Spotify:** log in with your own Spotify developer app, pick one of your playlists or Liked Songs, and colon3 rebuilds it as a playlist in the same order. Songs you already have are added right away; the rest are found on Soulseek and downloaded (right title, artist and length; lossless, high bitrate and free slots preferred; no live, remix or karaoke versions unless the original is one). Each song shows its progress, with Cancel and Retry Not Found.
- **Import from Apple Music:** the same for playlists in the Music app on your iPhone.
- **Playback speed:** a speed button in Now Playing opens a bar from 0.5× to 2× that snaps to common speeds. Pitch stays natural, and the speed is remembered.

### Fixed
- **Software Update:** Install Update now opens the install page and starts the iOS install prompt straight away, instead of trying an in-app install that iOS blocks.

### Removed
- **Discord status.** Any saved Discord token is deleted from the Keychain on first launch.

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
