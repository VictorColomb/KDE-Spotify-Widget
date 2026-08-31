# KDE Spotify Widget

A KDE Plasma 6 desktop widget that acts as a Spotify miniplayer — shows the
currently playing track, album art, and playback controls, without needing the
Spotify desktop app open.

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
- Python 3 (stdlib only — no pip installs needed) for the one-time setup
- KWallet, running and unlocked — `kwallet-query` must be on `PATH` (Fedora:
  `kf6-kwallet`).
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
4. Save and note your **Client ID** and **Client Secret**

### Step 2 — Authorize and Store Credentials

Run the one-time setup script from the repo root:

```bash
python3 setup_auth.py
```

It will:

1. Ask for your Client ID and Client Secret
2. Open a browser to the Spotify login/authorization page
3. Catch the callback automatically on `127.0.0.1` (verifying the OAuth `state`)
4. Store the **client secret** and **refresh token** in KWallet, then read them
   back to confirm the write landed

The two secrets are never printed and never written to a config file — they go
straight into KWallet, under wallet `kdewallet`, folder **Spotify Widget**. You
can inspect or remove them with `kwalletmanager5`. Only the Client ID, which is
not a secret, is echoed for you to paste into the widget.

### Step 3 — Install the Widget

```bash
kpackagetool6 --type Plasma/Applet --install spotify-widget/
```

To update an existing installation:

```bash
kpackagetool6 --type Plasma/Applet --upgrade spotify-widget/
```

Then restart Plasma if the widget doesn't appear immediately:

```bash
plasmashell --replace &
```

### Step 4 — Add and Configure the Widget

1. Right-click your desktop → **Add Widgets**
2. Search for **Spotify Widget** and drag it onto the desktop
3. Right-click the widget → **Configure Spotify Widget...**
4. In the **General** tab, fill in **Client ID** — that's the only field
5. Click **OK**

The widget reads the secret and refresh token from KWallet on startup. If the
wallet is locked, missing, or doesn't contain the entries, it shows an error and
does nothing — by design, there is no fallback to plaintext storage.

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

```bash
kpackagetool6 --type Plasma/Applet --remove org.kde.plasma.spotifywidget
```

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

- You haven't entered your Client ID yet — right-click → Configure

**"Could not read ... from KWallet" error**

- Make sure KWallet is running and unlocked (`kwalletmanager5`)
- Confirm the entries exist:
  `kwallet-query -f 'Spotify Widget' -r refreshToken kdewallet`
- If the folder doesn't exist, re-run `python3 setup_auth.py`
- This is intentional: the widget has no plaintext fallback and stays dark on
  failure

**Token expires / widget stops updating**

- The widget handles token refresh automatically; if it stops, right-click →
  Configure and re-paste your refresh token, then click OK to reinitialize

**The widget disappeared from the panel**

- Expected when Spotify has nothing loaded — it returns within 30s of playback
  starting
