# Changelog

CI uses the section matching the build's version as the GitHub Release notes and as the
"What's New" text in Settings › Software Update. Keep the heading format `## X.Y.Z`.

## 1.4.0

### New
- **Storage:** Settings › Library › Storage shows how much space your music takes, and which albums, artists and songs take the most, with a bar for each. Swipe one to delete it.
- **Songs you don't play:** the same page lists songs not played in 30 days: ones never played that were downloaded over 30 days ago, and ones last played over 30 days ago. Delete them all at once, or pick which. Favourites are left out unless you include them.
- **Find Lyrics:** when the automatic lyrics are missing or wrong, search LRCLIB yourself from the song menu, the Now Playing menu or the lyrics view. Results show whether they're synced and whether their length matches your song; preview one and tap Use These Lyrics to save it as the song's .lrc.
- **Find Cover Online:** Change Artwork › Find Cover Online shows the five best covers for an album or song from Apple Music, Deezer and MusicBrainz. Tap one to use it.

- **Romanized lyrics:** Japanese lyrics get romaji, Chinese pinyin with tone marks, and Korean its romanization, in smaller type under each line, worked out on the phone. Kanji in Japanese songs get their Japanese readings. Turn it off with Romanize Lyrics in the Now Playing menu.

- **Landscape player:** turn the phone sideways in Now Playing for a landscape layout: the artwork, lyrics or queue on the left, and the song, controls, volume and buttons on the right. The rest of the app stays in portrait.
- **Lyrics on the Lock Screen:** while a song with synced lyrics plays, the line being sung (with its romanization and the next line) shows on the Lock Screen as a Live Activity, and in the Dynamic Island when it's expanded. It starts when you play something with colon3 open and follows every song after that. Turn it off in the Now Playing menu or Settings › Playback.
- **Continue Listening:** the top of Home shows the song you stopped on, where you stopped, even after closing the app. Tap it to carry on with the same queue. Move or hide it in Settings › Appearance › Home Sections.
- **Go to Album:** in the Now Playing menu, opens the album of the song that's playing.

### Changed
- **Missing covers:** when Apple has no cover for an album or song, colon3 now also looks on Deezer and MusicBrainz's Cover Art Archive, and uses what it finds there if the title and artist match.

## 1.3.1

### Fixed
- **Home:** the charts no longer sit on an endless spinner when Apple's chart server is slow. The last charts that loaded show straight away and are replaced when fresh ones arrive; a server that doesn't answer is given up on after 25 seconds per try, and failures are written to Diagnostics & Logs.
- **Home when Apple Music's charts are down:** Apple's chart server has been answering "502 Bad Gateway". When it does, colon3 now uses the charts saved in the last three days, or else the old iTunes Store chart (top sellers rather than most played), and says so above the shelves.
- **Discord showing "Playing" instead of "Listening to":** in 1.3.0 a single update Discord didn't accept, often just a rate limit, switched the status to "Playing" for good. Failed updates are now retried, "Playing" is only used after repeated failures and only until colon3 restarts, and the stuck setting is cleared. The status under your name now reads "Listening to *artist*" through Discord's status display setting, like Discord Music Presence does.

## 1.3.0

Everything new since 1.2.0.

### New
- **Siri and Shortcuts:** control colon3 by voice, with no setup:
  - "Play music in colon3" resumes, or shuffles your library if nothing was queued.
  - "Play a song in colon3": Siri asks what you want to hear. Name a song, an album or an artist from your library, or say "*song* by *artist*".
  - "Play *playlist* in colon3" and "Shuffle *playlist* in colon3". Siri learns your playlist names as you make them.
  - "Shuffle colon3", "Play my favourites in colon3", "Pause colon3", "Next song in colon3", "Previous song in colon3" and "What's playing in colon3".
  - Every action is also in the Shortcuts app, and Siri can start music without opening colon3. The full list is in Settings › Siri & Shortcuts.
- **Discord:** show what you're listening to on your Discord profile, like Spotify does: "Listening to *artist*" with the song, album, cover and a progress bar. Sign in once in Settings › Discord; no token and no developer app of your own, unlike the old Discord status removed in 1.0.0. It shows while a song plays and clears when you pause. Covers come from Apple's catalogue, since Discord can only show images from the web.
- **AltStore and SideStore:** colon3 has its own source. Add `https://aminewallah.github.io/colon3/altstore.json` under Sources to install it from the store and get every new release under Updates.

### Fixed
- **Other apps' audio:** opening colon3 no longer stops a video or music playing in another app.
- **Voice messages and calls:** after you pause colon3, a voice message (in Instagram and other apps) picks up your voice straight away, and colon3 no longer starts playing by itself when you send or cancel it. colon3 now hands the audio back when you pause, and after an interruption it only resumes if it was playing when the interruption started.
- **Background transfers after an interruption:** downloads kept in the background by Keep Transfers Running in Background now carry on after a call or voice message, instead of stalling until you open the app.

### Changed
- **Settings** is split into pages with icons, each showing its current state on the main list: Soulseek, Transfers, Library, Playback, Appearance, Siri & Shortcuts, Last.fm, Discord, Spotify, Backup, Software Update and the logs. An "Update Available" row appears at the top when there is one.

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
