<p align="center">
  <img src="docs/logo.png" width="128" alt="colon3 icon">
</p>

<h1 align="center">colon3 (:3)</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2018.0%2B-0a84ff" alt="Platform: iOS 18.0+">
  <a href="https://github.com/AmineWallah/colon3/releases/latest"><img src="https://img.shields.io/github/v/release/AmineWallah/colon3?label=Latest%20release&color=brightgreen" alt="Latest release"></a>
  <a href="https://github.com/AmineWallah/colon3/releases"><img src="https://img.shields.io/github/downloads/AmineWallah/colon3/total?label=Download&color=brightgreen" alt="Downloads"></a>
</p>

A native Soulseek client and music player for iOS. Search the Soulseek network, download straight to the phone, and play from a local library. No server or desktop client in between.

- **Library:** albums and loose songs in a 2-column grid, A–Z side scrubber, Songs, Artists and Playlists views, favourites, multi-select, and import from Files or other apps.
- **Playlists:** your own (reorder, rename, .m3u8 import/export), plus Favorite Songs and Most Played.
- **Home:** Apple Music-style shelves for trending songs, the top 100, recent releases and recently played, with one-tap downloads from Soulseek.
- **Spotify, Apple Music and YouTube Music import:** rebuild a Spotify playlist or your Liked Songs, an Apple Music playlist, or a YouTube Music playlist link from your library, downloading what's missing from Soulseek in the original order.
- **Artwork:** a cover you picked (Photos or Files), then cover files from the album folder, then art embedded in the music, then an iTunes lookup. Album downloads fetch the folder's cover (and any .lrc lyrics) from the peer too.
- **Player:** Apple Music-style full screen with synced lyrics (a .lrc next to the song, else LRCLIB), queue editing, shuffle and repeat, playback speed, AirPlay, and the Liquid Glass mini player on iOS 26+.
- **Autoplay:** when the queue ends, similar songs keep playing (Last.fm similar tracks and artists, else the same artist, most played or random). Picks you don't have get a Download button (or download on their own, if you turn that on) and play once they're downloaded from Soulseek.
- **Sound:** 10-band EQ with presets, and a bit-perfect mode for USB DACs. Multichannel and Dolby Atmos files play through AVPlayer with spatial audio instead, with no EQ.
- **Transfers:** multi-select retry/cancel/clear/delete, a Live Activity, Seeding Mode, and Wi-Fi Transfer from a computer's browser.
- **Stats:** listening time, top songs/artists/albums, upload/download totals.
- **Backup:** your song list, playlists, favourites, stats and settings to Google Drive (daily if you like) or a file, optionally with the music itself. Restoring brings it all back and downloads missing songs from Drive or Soulseek.
- **Last.fm** scrobbling with your own API key, which autoplay also uses for recommendations.
- **Discord:** "Listening to colon3" on your profile with the song, artist and album cover, after signing in once (builds made with Discord's SDK).
- **Siri and Shortcuts:** "Play music in colon3", "Play a song in colon3", "Play <playlist> in colon3", "Shuffle colon3", pause, skip and more, with no setup.

Meant for sideloading. It won't pass App Store review.

## Layout

```
App/
  Library/                 scanning, metadata (incl. a small FLAC tag reader), albums, artwork, favourites
  Playback/                AVAudioEngine + EQ backend, AVPlayer spatial backend, queue
  Import/                  Spotify, Apple Music and YouTube Music playlist import
  Services/                LRCLIB lyrics, Last.fm, Google Drive backup, Siri intents, keychain and settings
  Soulseek/                search results, downloads, cover fetching
  Views/                   SwiftUI screens
Packages/SoulseekKit/      Protocol package (no dependencies)
  Sources/SoulseekKit/
    Bytes, Framing, Zlib, MD5        primitives, all Linux-testable
    ServerMessages, PeerMessages     message codecs
    SoulseekClient.swift             Network.framework client (Apple platforms only)
  Tests/SoulseekKitTests/            codec tests against bytes produced by Nicotine+
scripts/gen_fixtures.py    regenerates the test fixtures from Nicotine+'s encoders
scripts/make-ota-site.py   builds an over-the-air install page for a signed IPA
scripts/fetch-discord-sdk.sh  CI: fetches Discord's Social SDK from a private repository
DiscordBridge/             Objective-C++ bridge to Discord's SDK (only built with project-discord.yml)
docs/logo.png              the README's icon (AppIcon with rounded corners)
pages/privacy.html         privacy policy, deployed to the Pages site root (linked from Google sign-in)
project.yml                XcodeGen spec
project-discord.yml        project.yml plus Discord's SDK, used by CI when it has the SDK
.github/workflows/build.yml  CI/CD: tests, IPA build, signing, install page, releases
```

## Building

### Protocol tests (Linux, no Mac needed)

```sh
# Needs a Swift toolchain: the swift.org tarball, or `swift-bin` from the AUR on CachyOS
swift test --package-path Packages/SoulseekKit
```

The tests decode and encode byte streams generated by Nicotine+'s own message classes, so a failure means we disagree with a real client. To regenerate them:

```sh
git clone --depth 1 https://github.com/nicotine-plus/nicotine-plus /tmp/nicotine-plus
python3 scripts/gen_fixtures.py /tmp/nicotine-plus > Packages/SoulseekKit/Tests/SoulseekKitTests/Fixtures.swift
```

### App in a macOS VM

```sh
xcodegen generate
xcodebuild -project colon3.xcodeproj -scheme colon3 -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/colon3.app Payload/ && zip -qry colon3.ipa Payload
```

Homebrew no longer supports Intel Macs, which includes QEMU macOS VMs. Install XcodeGen from its [release zip](https://github.com/yonaskolb/XcodeGen/releases) instead: copy `bin/xcodegen` to `/usr/local/bin` and `share/xcodegen` to `/usr/local/share`.

## CI/CD

`.github/workflows/build.yml` runs on every push and pull request:

| Job | When | What it does |
|---|---|---|
| Protocol tests | always | `swift test` for SoulseekKit on Linux |
| Build unsigned IPA | always | XcodeGen + `xcodebuild` on a macOS runner. Version comes from `MARKETING_VERSION` in `project.yml` (or the tag), build number from the run number. The IPA is kept as a run artifact for 30 days. |
| Sign and stage install page | pushes to `main` or `beta`, if signing secrets are set | Signs the IPA with zsign and the distribution cert, checks the cert's revocation status (shown in the run summary), and builds the install page: `main` at the site root, `beta` under `/beta/` |
| Deploy install page | after signing | Publishes the page to GitHub Pages |
| GitHub Release | tags `v*` | Attaches the unsigned IPA to a release (a pre-release for tags like `v0.4.0-beta.1`) |

The macOS runner is only free for public repos.

### One-time setup for the install page

1. **Enable Pages:** repo Settings › Pages › Build and deployment › Source: **GitHub Actions**.
2. **Add the signing secrets** from the folder holding your distribution `.p12` and `.mobileprovision` (works in fish and bash):
   ```sh
   base64 -w0 dist.p12 | gh secret set SIGNING_P12_BASE64
   gh secret set SIGNING_P12_PASSWORD        # prompts for the password
   base64 -w0 dist.mobileprovision | gh secret set SIGNING_PROFILE_BASE64
   ```
3. **Only if the profile is locked to one bundle ID** (its `application-identifier` isn't `TEAMID.*`), set that ID as a variable:
   `gh variable set SIGN_BUNDLE_ID --body com.example.app`

After that, every push to `main` updates `https://<user>.github.io/colon3/`. Open it in Safari on the phone and tap **Install**. Installing over an existing copy keeps your downloaded music and login.

Things to know:
- **The page is public.** Pages on a public repo is open to anyone who finds the URL. It's marked `noindex`, but anyone with the link can install your signed build. That's harmless for you, but wide distribution under a shared enterprise cert makes revocation more likely.
- **Secrets never reach pull requests.** The signing job only runs for pushes to `main`.
- **If the cert gets revoked,** the run summary's certificate check shows it. Replace the three secrets with the new cert and re-run the workflow.

### One-time setup for Google Drive backups

Backups talk to the Google Drive API directly, so the app needs an OAuth client ID from a Google Cloud project. You make it once; everyone using your build just taps Connect Google Drive and signs in. It's free.

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project (e.g. `colon3`).
2. **APIs & Services › Library:** find **Google Drive API** and tap **Enable**.
3. **Google Auth Platform** (the OAuth consent screen):
   - **Branding:** the app name and your email. Leave out the logo, or Google wants to review the branding first. Publishing also needs a homepage and a privacy policy: use the install page, `https://<user>.github.io/colon3/`, and `https://<user>.github.io/colon3/privacy.html` (from `pages/privacy.html`, deployed with the install page). Add `<user>.github.io` under **Authorized domains**.
   - **Audience:** **External**.
   - **Data Access:** add the scope `https://www.googleapis.com/auth/drive.file`.
4. **Clients › Create client:** type **iOS**, bundle ID `com.aminewallah.colon3` (or your `SIGN_BUNDLE_ID`). No secret is made for iOS clients. Copy the client ID, which ends in `.apps.googleusercontent.com`.
5. **Audience › Publish app.** While it's in Testing, only the test users you list can sign in and their sign-in expires after 7 days. `drive.file` is a non-sensitive scope, so publishing needs no review: colon3 can only see the files it creates, not the rest of anyone's Drive.
6. Give CI the client ID (it isn't secret):
   ```sh
   gh variable set GOOGLE_CLIENT_ID --body 1234567890-abc123.apps.googleusercontent.com
   ```
   For a local build, put it in `COLON3_GOOGLE_CLIENT_ID` in `project.yml` instead.

A build without a client ID still has Settings › Backup: it asks for one there, and backup files work without Google at all.

### One-time setup for Discord

Discord Rich Presence uses Discord's Social SDK. Users just tap Connect Discord; you set up one Discord application and give CI the SDK. The SDK is closed source and its terms don't allow redistributing it, so it never goes in this repository: CI downloads it from a **private** repository of yours. Builds without it work normally and say so in Settings › Discord.

1. In the [Discord Developer Portal](https://discord.com/developers/applications), create an application named **colon3** and give it the app icon (the presence falls back to it when a song has no cover online).
2. **Getting Started / Social SDK:** enable the Social SDK for the application (fill in the short form if asked).
3. **OAuth2:** add the redirect `discord-<APPLICATION_ID>:/authorize/callback` and turn on **Public Client** (colon3 has no server, so it signs in with PKCE like the Google and Spotify logins).
4. **Downloads:** download the Social SDK for **iOS** (a zip with `discord_partner_sdk.xcframework`).
5. Make a private repository and attach the zip to a release there:
   ```sh
   gh repo create colon3-vendor --private
   gh release create discord-sdk --repo <user>/colon3-vendor --title "Discord Social SDK" ~/Downloads/DiscordSocialSdk-*.zip
   ```
   For a new SDK version, upload a new release; CI takes the latest one.
6. Create a [fine-grained token](https://github.com/settings/personal-access-tokens/new) with access to **only** that repository and **Contents: Read-only**, then give CI the token, the repository and the application ID:
   ```sh
   gh secret set DISCORD_SDK_TOKEN            # paste the token
   gh variable set DISCORD_SDK_REPO --body <user>/colon3-vendor
   gh variable set DISCORD_APP_ID --body <APPLICATION_ID>
   ```

The next build logs "Building with Discord Rich Presence". The privacy policy page already covers what's sent to Discord.

### Beta channel

Push risky changes to a `beta` branch first. Its signed build goes to `<pages url>/beta/` and leaves the stable page alone; each deploy copies the other channel's files from the live site so both stay up. Builds report their channel, and Settings › Software Update follows the matching page (switchable between Stable and Beta).

One-time: Settings › Environments › `github-pages` › Deployment branches and tags › add `beta`, or its deploy is rejected.

When the beta works, fast-forward main to it:

```sh
git switch main && git merge --ff-only beta && git push
```

### Releases

Write the notes in `CHANGELOG.md` under `## X.Y.Z` before tagging. CI uses that section for the GitHub Release and for "What's New" in Settings › Software Update.

```sh
git tag v0.2.0 && git push origin v0.2.0
```

This builds version 0.2.0 and attaches `colon3-0.2.0-unsigned.ipa` to a GitHub Release, ready for SideStore or any signer.

## Installing

- **Install page (recommended):** see [CI/CD](#cicd). Push to `main`, then open the Pages URL in Safari.
- **Locally, without CI:** sign the IPA, then serve an install page through a temporary HTTPS tunnel:
  ```sh
  zsign -k dist.p12 -p 'PASSWORD' -m dist.mobileprovision -o colon3-signed.ipa colon3.ipa
  cloudflared tunnel --url http://localhost:8000      # note the https:// URL it prints
  python3 scripts/make-ota-site.py colon3-signed.ipa --base-url https://<tunnel-url> --out ~/colon3-dist
  cd ~/colon3-dist && python3 -m http.server 8000
  ```
  Serve only that output folder, never your home or Downloads folder. Stop both servers when you're done.
- **SideStore / AltStore:** open the unsigned IPA from a release or workflow artifact. They sign it with your Apple ID on-device. Free accounts: 7-day expiry, 3 apps max.

## Using it

1. **Account tab:** enter a username and password. An unused username gets registered on first login. There's no password reset. Soulseek's rules forbid throwaway or random usernames, so pick a real one.
2. **Search:** results stream in over roughly 30 seconds and are grouped by folder (usually an album). Free-slot peers sort first.
3. Open a folder, tap a file or **Download all**.
4. Finished files go to *On My iPhone › colon3 › Music*. They show up in the Files app, and you can drop your own music there too.
5. **Library:** tap an album, or long-press anything for Play Next, Add to Queue, Favorite and Delete. **Select** enables multi-select.
6. **Player:** tap the mini player. The speech-bubble button shows lyrics (tap a line to jump there) and the list button the queue. The ••• menu opens the equalizer.

### Software Update

Settings › Software Update compares the installed build with `version.json`, which CI publishes next to the install page on every signed build. **Get Update on GitHub** opens the [latest release](https://github.com/AmineWallah/colon3/releases/latest) on Stable, or the [releases list](https://github.com/AmineWallah/colon3/releases) on Beta, with the IPA for SideStore or any signer. **Install from Install Page** opens the over-the-air install prompt instead. Either way the music library and settings are kept. The Settings tab shows a badge when an update is waiting.

### Links

`colon3://player`, `colon3://home`, `colon3://downloads`, `colon3://library`, `colon3://search?q=…` and `colon3://wifi` open those screens, for Shortcuts or Back Tap (Settings › Accessibility › Touch › Back Tap › a shortcut that opens the URL). Tapping the transfers Live Activity opens Downloads.

### Bit-perfect mode

Settings › Playback. With a wired USB DAC, each song's sample rate is requested from the hardware and the EQ and gain stages are skipped, so the DAC receives the file's samples unchanged. Keep the iPhone volume at maximum and use the DAC's volume. The Now Playing badge says when it's achieved, or why not (Bluetooth, AirPlay, the speaker, or a DAC that refused the rate).

### Wi-Fi Transfer

Settings › Transfers › Wi-Fi Transfer (or `colon3://wifi`), then open the address on a computer on the same network and enter the code. Drop files or folders in, download or delete files. Over a cable on Linux: `ifuse --documents com.aminewallah.colon3 ~/iphone`.

### Last.fm

Create an API account at [last.fm/api/account/create](https://www.last.fm/api/account/create) (any app name works). In Settings › Last.fm, enter the API key, shared secret, your username and password. The password is only used once to get a session key. Everything is stored in the Keychain. Scrobbles made offline are queued and sent later.

### Autoplay

On by default (Settings › Playback, or the ∞ button above the queue). When the queue ends, colon3 plays songs Last.fm lists as similar to the last song (`track.getSimilar`) or by similar artists (`artist.getSimilar`). Both only need the API key from the Last.fm section.

- **Songs in your library** play straight away.
- **Songs you don't have** (up to half of each batch, also from similar artists' top tracks via `artist.getTopTracks`) show under Up Next with a **Download** button. Confirm it and the song is searched on Soulseek and downloaded (two at a time, in list order), matched the same way as imports, into a **Found by Autoplay** playlist you can keep or clean out. If it isn't ready when its turn comes, the next ready song plays and it follows once it's done. Suggestions you don't download are dropped when playback passes them. Settings › Playback › **Download Suggestions Automatically** downloads them without asking; **Autoplay Only from Library** never suggests them. Downloads only happen while you're logged in to Soulseek.
- **Without a key**, or when Last.fm has nothing, it falls back to more by the same artist, then your most played, then random.

Songs played recently are skipped, and the next ten show under Up Next with their download progress. Autoplay and imports share one Soulseek search queue (at most one search every 10 seconds), and autoplay's searches go first.

### Importing from Spotify

You need your own Spotify developer app. Since February 2026 the app's owner needs Spotify Premium.

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) and choose **Create app**.
2. Give it any name and description. Add the redirect URI `colon3://spotify-callback` exactly, under **Redirect URIs**, and click **Add**.
3. Under **Which API/SDKs are you planning to use?**, tick **Web API**. Accept the terms and **Save**.
4. Open the app's **Settings** and copy the **Client ID**. You don't need the client secret.
5. In colon3, open **Settings › Spotify** or **Library › Playlists › Import from Spotify…**, paste the Client ID and tap **Log In with Spotify**.

To log in with a Spotify account other than the app owner's, add it under **User Management** in the dashboard (apps created since February 2026 allow up to 5 users).

Then pick a playlist or Liked Songs. Songs already in your library go straight into a new colon3 playlist. The rest are searched on Soulseek one at a time, ten seconds apart, and the best file is downloaded. "Best" means the title, artist and length match; lossless or high bitrate and peers with free slots are preferred; and live, remix, karaoke and similar versions are skipped unless the original is one. If a download fails or stalls for 3 minutes, the next-best file is tried. Songs that can't be found can be retried later.

Spotify only shows development-mode apps the songs of playlists **you own or collaborate on**. Playlists you just follow, including Spotify's own, are listed but greyed out. A workaround is to copy one into a playlist of your own in Spotify first.

### Home

The first tab is laid out like Apple Music's, with four shelves you can reorder or hide in Settings › Appearance › Home Sections:

- **Trending Songs:** songs on Apple Music's top 100 that came out recently (in the last 6 weeks, widening to 3 or 6 months when there are fewer than 8), in chart order.
- **Top 100:** Apple Music's 100 most played songs.
- **Recent Releases:** albums on Apple Music's top 100 albums chart that came out recently, newest first.
- **Recently Played:** albums and songs from your library, most recent first.

The charts come from Apple's public feed at `rss.marketingtools.apple.com` for the country picked with the globe button (it starts on your region). No key is needed, and they update daily. A tick means a song or album is in your library: tap a song to play it, with the shelf's other songs you have queued after it, or an album to open it. Otherwise a song's download button finds it on Soulseek through the same search queue and matching as imports and autoplay.

Tapping a release opens its page: the full tracklist from Apple's lookup API (`itunes.apple.com/lookup`, no key; the US store is used when your country's store doesn't list the songs), with a tick on the songs you have and a download button on the rest. **Download Missing** fetches each missing song on its own, matched by title, artist and exact length. **Find Album** opens the Search tab with the album searched instead, for getting the whole album folder from one peer. **Open in Library** appears once you have the album. Downloads keep going if you leave the tab. Tap a shelf's title for the full list.

Spotify can't be used for this: since February 2026, development-mode apps can't read Spotify's browse endpoints or its own Top 50 playlists.

### Importing from YouTube Music

Library › Playlists › Import from YouTube Music…, then paste a playlist link from YouTube Music or YouTube (Share › Copy link). No account, API key or setup is needed.

- **Public or Unlisted playlists only.** Liked Music and private playlists can't be read from a link. Put those songs in a playlist, set it to Unlisted, and paste its link.
- **How it reads them:** colon3 loads the playlist's youtube.com page, which carries the first 100 songs, and fetches the rest the way the website does when you scroll. This isn't an official API: if YouTube changes its pages, import stops working until colon3 is updated. (In 2026 YouTube moved playlist items to a new layout; both the old and the new one are read.)
- **Titles:** YouTube Music tracks (from "Artist - Topic" channels) give the artist and the song's exact length. For music videos, "Artist - Song (Official Video)" is split into artist and song, and the video's length isn't used, since intros and outros make it differ from the song.

### Importing from Apple Music

Library › Playlists › Import from Apple Music… asks for access to your Music library and lists its playlists. They're matched and downloaded the same way. colon3 only reads song names; it can't copy Apple Music's own files.

### Siri and Shortcuts

These phrases work as soon as colon3 is installed (Settings › Siri & Shortcuts lists them):

| Say | Does |
|---|---|
| "Play music in colon3" / "Resume colon3" | Resumes, or shuffles the library if nothing was queued |
| "Play a song in colon3" | Asks what you want to hear: a song, album or artist from your library, or "*song* by *artist*" |
| "Play *playlist* in colon3" / "Shuffle *playlist* in colon3" | Plays one of your playlists |
| "Shuffle colon3" | Shuffles the whole library |
| "Play my favourites in colon3" | Shuffles favourite songs and albums |
| "Pause colon3", "Next song in colon3", "Previous song in colon3" | Transport |
| "What's playing in colon3" | Says the current song |

They're App Intents, so they need no SiriKit entitlement and work in sideloaded builds; every action also shows up in the Shortcuts app. They are audio-playback intents, so Siri can start music without bringing colon3 to the front.

### Discord

Settings › Discord › **Connect Discord** signs in through Discord's website (or a Discord login already in Safari) and turns it on. While a song plays, your profile shows "Listening to colon3" with the song, artist, album cover and progress, and the status next to your name shows the song title. Pausing clears it. Covers are looked up in Apple's catalogue (the iTunes Search API), because Discord can only load images from the web; songs it can't find show the colon3 icon.

Discord's SDK documentation calls "Playing" the activity type that matters for it; colon3 asks for "Listening" first and, if Discord turns that down, falls back to "Playing colon3" and says so in Settings (with a button to try Listening again). It keeps working in the background as long as music plays, since that's what keeps colon3 running.

### Backup

Settings › Backup. **Connect Google Drive**, then **Back Up Now**. The backup is `colon3-backup.json` in a **colon3 Backup** folder in your Drive: a readable list of every song (path, title, artist, album, track number, length), your playlists, favourites, listening stats and settings. Passwords, tokens and API keys are never in it.

- **Back Up Automatically:** once a day, when you open colon3. It only starts after this phone has backed up or restored once, so a fresh install can't replace your backup with an empty one.
- **Include Music:** also uploads the song files (with their covers and .lrc lyrics) into `colon3 Backup/Music/`, in the same folders as on the phone. Each backup only sends what's new or changed. Uploads wait for Wi-Fi unless **Use Cellular Data** is on, and keep going in the background while **Keep Transfers Running in Background** is on. Files you delete from colon3 stay in Drive; delete them there if you want the space back.
- **Restore:** brings back playlists (replacing any with the same identity), adds favourites and stats to what's there, and optionally settings. Songs already on the phone are found by file or by title and artist. The rest are listed under **Missing Songs**: download them from the Drive music backup, or find them on Soulseek (just the ones in playlists and favourites, or all of them). Playlists keep their place for missing songs and fill in as they arrive, including songs you copy in yourself.
- **Backup File:** **Export Backup File** shares the same backup as a `.json` (without the music) and **Import Backup File** restores one, with no Google account involved.
- **Disconnect** signs out and removes colon3's access from your Google account; the backup stays in Drive.

## How it works (and what it can't do)

iOS apps can't usefully accept incoming connections: no port forwarding on mobile data/CGNAT, and the OS suspends the app in the background. So colon3 **never listens**.

- **Receiving search results and files:** a peer that can't reach us asks the server to relay a `ConnectToPeer`. colon3 dials out to that peer and sends `PierceFireWall`. This only works if *the peer* has an open port, which most dedicated sharers do.
- **Requesting downloads:** colon3 opens a direct connection (`GetPeerAddress` → `PeerInit`) and sends `QueueUpload`. Any peer that just sent us results is reachable, so this works.
- **Peers who are also firewalled** can't exchange anything with us. Their results never arrive, so you won't see them.
- **Background:** transfers stall when iOS suspends the app. Playing music keeps the app alive (background audio mode), so downloads continue while you listen. Partial files are kept in Application Support/Incomplete, and retrying resumes from where the transfer stopped.
- **Sharing back:** downloaded music is shared under a virtual `colon3\…` folder. colon3 answers browse requests and serves uploads one at a time, but only to peers it can connect to directly. The distributed search network is not joined, so other users' searches won't find your files.
- **Formats:** "Playable formats only" (on by default) hides what AVPlayer can't decode on iOS: Ogg Vorbis, Opus outside CAF, WMA, APE.

Protocol details follow Nicotine+'s [`SLSKPROTOCOL.md`](https://github.com/nicotine-plus/nicotine-plus/blob/master/doc/SLSKPROTOCOL.md). The client logs in with major version 177, which the doc reserves for experimental clients.

## Debugging

The *Account › Connection log* screen shows server/peer events. For protocol work, run Nicotine+ on your PC with a second account. Search for something only it shares, and watch both sides.
