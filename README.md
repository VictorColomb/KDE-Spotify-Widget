# KDE Spotify Widget

A KDE Plasma 6 desktop widget that acts as a Spotify miniplayer — shows the
currently playing track, album art, and playback controls, without needing the
Spotify desktop app open.

<img width="450" alt src="https://github.com/user-attachments/assets/457e7825-bbc6-48f6-a18b-51d529953700" />

## Features

- Album art, track name, and artist display
- Play/Pause, Skip Next, Skip Previous controls
- Progress bar with timestamps (ticks smoothly between API polls)
- Panel view: album art, bold track name, artist — sized to the title, hidden
  when Spotify is idle
- Auto token refresh — stays authenticated without any manual intervention

> **Note:** Playback control requires a **Spotify Premium** account.

---

## Prerequisites

- KDE Plasma 6
- KWallet, running and unlocked — `kwallet-query` must be on `PATH` (Fedora:
  `kf6-kwallet`; Arch: `kwallet`).
- A C++ toolchain and the KWallet headers, to build the widget's wallet plugin:
  - Fedora:
    `cmake extra-cmake-modules gcc-c++ kf6-kwallet-devel kf6-kpackage-devel kf6-kcoreaddons-devel qt6-qtdeclarative-devel`
  - Arch:
    `cmake extra-cmake-modules base-devel kwallet kpackage qt6-declarative`
  - Debian/Ubuntu:
    `cmake extra-cmake-modules build-essential libkf6wallet-dev libkf6package-dev qt6-declarative-dev`
- A [Spotify Developer app](https://developer.spotify.com/dashboard) (free to
  create)

---

## Setup

### Step 1 — Create a Spotify Developer App

1. Go to
   [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
   and log in
2. Click **Create app**, give it any name, select **Web API**
3. In the app settings, add the following as a **Redirect URI**:
   ```
   http://127.0.0.1:8888/callback
   ```
4. Save and note your **Client ID**. There is no need for the Client Secret —
   the widget authenticates with PKCE.

### Step 2 — Build and Install

The widget talks to KWallet through a small C++ QML plugin, so there is one
build step. From the repo root:

```bash
cmake -B build
cmake --build build
sudo cmake --install build
```

This installs both the wallet plugin and the widget itself, system-wide.

`cmake -B build` prints the prefix it chose. Leave it alone unless you have a
reason not to: Qt only looks for QML modules under its own prefix, so the CMake
default of `/usr/local` would install a plugin the widget can never load, and
the configure step defaults to Qt's prefix to avoid exactly that. If you do pass
`-DCMAKE_INSTALL_PREFIX=...`, CMake will warn you when the result won't be
found.

Then restart Plasma if the widget doesn't appear immediately:

```bash
plasmashell --replace &
```

To update after pulling changes, re-run the same three commands.

### Step 3 — Add, Configure, and Authorize the Widget

1. Right-click your desktop → **Add Widgets**
2. Search for **Spotify Widget** and drag it onto the desktop
3. Right-click the widget → **Configure Spotify Widget...**
4. In the **General** tab, paste your **Client ID**
5. Click **Authorize with Spotify** — it opens your browser to Spotify's login
   page and stores the refresh token in KWallet as soon as you approve access
6. Click **OK**

The widget picks up the token immediately — no plasmashell restart needed. If
the wallet is locked, missing, or doesn't contain the entry, it shows an error
and does nothing — by design, there is no fallback to plaintext storage.

The widget will start showing your currently playing track within a couple of
seconds.

---

## Usage

| Control               | Action                        |
| --------------------- | ----------------------------- |
| ⏮                     | Skip to previous track        |
| ⏯                     | Play / Pause                  |
| ⏭                     | Skip to next track            |
| Click the panel entry | Open / close the player popup |

The panel entry hides itself when Spotify has no track loaded, and reappears
when playback starts. It stays visible while paused, and while unconfigured or
if KWallet can't be read — otherwise there would be no way to right-click it.

The progress bar advances locally every second. The widget only calls Spotify to
catch changes made elsewhere: every 5s with the popup open, 15s while playing in
the panel, 30s when paused or idle, plus an immediate poll the moment a track
ends.

---

## Uninstall

Remove the widget from your panel or desktop first, then delete what was
installed:

```bash
sudo rm -rf /usr/share/plasma/plasmoids/org.kde.plasma.spotifywidget
sudo rm -rf /usr/lib/qt6/qml/org/kde/private/spotifywidget
```

Those are the paths for the default prefix; adjust them if you installed
elsewhere. Note the second one ends at `spotifywidget` — `org/kde/private/`
itself holds other KDE modules.

Finally, remove the stored token in `kwalletmanager5` (folder **Spotify
Widget**).

---

## Troubleshooting

**Widget shows "Not playing" even though Spotify is running**

- Make sure Spotify is actively playing on a device (phone, browser, or desktop
  app)
- The Spotify API only reports playback when something is actively playing or
  paused mid-track

**Playback controls don't work**

- Spotify Premium is required for API playback control
- Check that your credentials are entered correctly in the widget config

**"Configure widget" warning appears**

- You haven't entered your Client ID and authorized yet — right-click →
  Configure

**"Authorization failed" / "State mismatch" / token exchange error in
Configure**

- Make sure `http://127.0.0.1:8888/callback` is registered as a Redirect URI in
  your Spotify Developer Dashboard app
- Nothing else is listening on port 8888
- Click **Authorize with Spotify** again — each attempt starts a fresh PKCE
  exchange

**"KWallet has no ..." error**

- Make sure KWallet is running and unlocked (`kwalletmanager5`)
- The message names the exact wallet and folder it looked in; confirm the entry
  exists with
  `kwallet-query -f 'Spotify Widget' -r refreshToken <that wallet name>`
- If it doesn't, right-click → Configure → **Authorize with Spotify**
- This is intentional: the widget has no plaintext fallback and stays dark on
  failure

**The widget is blank, or nothing happens at all**

- The QML plugin probably isn't where Qt looks for it. Re-run `cmake -B build`
  and read the prefix it reports, then
  `cmake --build build && sudo cmake --install build`
- `journalctl --user -t plasmashell -f` will show the import failure

**Upgrading from a version that used a Client Secret**

- Right-click → Configure → **Authorize with Spotify** again.
- Your old `clientSecret` entry stays in the wallet, unused and ignored by the
  widget. Delete it in `kwalletmanager5` (folder **Spotify Widget**) whenever
  you like.

**Token expires / widget stops updating**

- The widget refreshes and re-stores the token automatically; if it stops,
  right-click → Configure → **Authorize with Spotify** again

**The widget disappeared from the panel**

- Expected when Spotify has nothing loaded — it returns within 30s of playback
  starting
