# AGENTS.md

## Commands

```bash
cmake -B build && cmake --build build                             # C++ wallet plugin
sudo cmake --install build                                        # plugin + applet, system-wide
kpackagetool6 --type Plasma/Applet --upgrade spotify-widget/      # QML-only iteration, per-user
plasmashell --replace &                                           # reload Plasma to pick up changes
kwallet-query -f 'Spotify Widget' -r refreshToken kdewallet       # wallet name: see Configure dialog
```

Widget `console.log`/`console.error` output goes to the `plasmashell` journal:
`journalctl --user -f -t plasmashell`.

To exercise a plugin type standalone (no Plasma, e.g. poking `OAuthCallback`
with `curl`), run a throwaway `.qml` file with `qml-qt6 -a core -I build/bin
file.qml` (binary name varies by distro like `qmllint`'s does; `-a core`
skips needing a display server). Set `QT_LOGGING_TO_CONSOLE=1` too, or
`console.log`/`console.warn` silently goes to journald instead of
stdout/stderr in sandboxed/CI shells.

## Quality gates

Run these before committing anything you touched. All four are non-zero on
failure, so they chain with `&&`.

```bash
cmake --build build                                        # C++ must compile warning-free
./qmllint.sh spotify-widget/contents/ui/main.qml           # and any other .qml you edited
```

Notes:

- `qmllint.sh` wraps Qt6's `qmllint`, whose binary name differs by distro. Never
  call plain `qmllint` directly. It is the only QML check there is; there is no
  QML build step, so a typo otherwise surfaces as a silently blank widget. It
  exits non-zero on real errors and 0 on warnings, so **read the output**, not
  just the status. The baseline is clean — any warning is yours.
- The wrapper passes `-I build/bin` when that directory exists. Without it,
  `main.qml`'s import of the wallet plugin is unresolved and every call into it
  goes unchecked, so **build before you lint** or the gate quietly weakens.
- A stale **system-wide** copy of the plugin (from a previous
  `sudo cmake --install`) shadows `build/bin` for qmllint's default import
  search and can make a type added since that install (e.g. a new
  `OAuthCallback` method) falsely report as "Unqualified access".
  `sudo cmake --install build` refreshes it; `./qmllint.sh --bare ...` confirms
  it's the stale copy at fault, not your code — `--bare` drops _all_ default
  import dirs, not just the stale one, so expect noisy "Failed to import"
  warnings for QtQuick/Kirigami/Plasma too; only the wallet-plugin warning
  disappearing is the signal.

## Architecture

Two pieces:

- `src/` — a C++ QML module, `org.kde.private.spotifywidget.wallet`, exposing
  `Wallet` (wraps `KF6::Wallet`) and `OAuthCallback` (a one-shot loopback
  listener for the Spotify redirect, plus PKCE helpers). Built by CMake;
  installed into Qt's QML import path.
- `spotify-widget/` — the Plasma 6 applet. Playback logic lives in
  [main.qml](spotify-widget/contents/ui/main.qml); the one-time "Authorize with
  Spotify" PKCE dance lives in
  [configGeneral.qml](spotify-widget/contents/ui/configGeneral.qml) — both
  configuring and authorizing happen in the widget's own Configure dialog.

### Credential flow

Only the non-secret Client ID lives in the plasmoid config (`main.xml`). The
refresh token lives in KWallet, folder **Spotify Widget**, in whichever wallet
`KWallet::Wallet::LocalWallet()` reports — nothing hardcodes `kdewallet`.

Authentication is pure PKCE: there is no client secret anywhere. Spotify rotates
the refresh token on renewal, and `main.qml:persistRefreshToken` writes each new
one straight back through the plugin. A rotation that is accepted but not stored
would log the widget out at the next restart, so a failed write is surfaced as
`walletError` rather than swallowed.

There is deliberately **no plaintext fallback**: if the wallet is locked or
empty, the widget shows an error and does nothing. Don't add one.

### The wallet plugin

`WalletBridge` is a QML singleton exposing `read`, `write` and
`localWalletName`. Three things about it are load-bearing:

- **The open is asynchronous, and must stay that way.** A locked wallet makes
  `openWallet` wait on a password prompt; the synchronous variant would do that
  on plasmashell's GUI thread and freeze the whole panel. Requests arriving
  before `walletOpened(bool)` are queued, and a failed open fails the whole
  queue with a message rather than hanging.
- **A failed open returns to `Closed`, not to a terminal error state**, so a
  user who cancels the unlock prompt and then unlocks the wallet gets a working
  widget on the next request instead of needing a Plasma restart.
- **Callbacks are always deferred**, even when the wallet is already open, so a
  caller never has to handle both same-tick and later delivery.

Per-request `setFolder`/`readPassword`/`writePassword` are synchronous D-Bus
calls, which is fine: on an already-open wallet they never prompt.

`WalletBridge` also emits `wroteEntry(folder, key)` after every successful
write. QML singletons are shared shell-wide, so `main.qml`'s own listener on
that signal is what lets it reload the moment `configGeneral.qml`'s "Authorize
with Spotify" writes a fresh `refreshToken` — no plasmashell restart, no
`Plasmoid.configuration` round-trip needed.

### The Authorize-with-Spotify flow

`configGeneral.qml` runs the whole PKCE dance that `setup_auth.py` used to do
from a terminal: `OAuthCallback.randomToken()` generates the verifier and
`state` (QML has no secure RNG), `OAuthCallback.pkceChallenge()` hashes the
verifier (QML has no SHA-256), `OAuthCallback.listen(8888)` starts the loopback
server, and `Qt.openUrlExternally()` opens the browser — the same URL is also
left in a read-only field as a copy-paste fallback in case that call can't reach
a browser. `OAuthCallback.callbackReceived` delivers `code`/`state`/ `error`; a
`state` mismatch is treated as a rejected callback, same as `setup_auth.py`'s
`_parse_callback`. The code exchange is the same `XMLHttpRequest` POST
`main.qml:refreshAccessToken()` already does.

### Installation is the sharp edge

Qt scans only its own QML directory for imports, so CMake's default
`/usr/local` prefix installs a module nothing can ever import — and the failure
mode is a blank widget with no error anywhere. The top-level `CMakeLists.txt`
therefore defaults the prefix to Qt's own and warns loudly if an explicit
prefix would put the module somewhere Qt will not look. Don't "simplify" that
away.

`kpackagetool6 --upgrade` still works for QML-only iteration, but it installs
per-user into `~/.local/share/plasma/plasmoids/`, which then shadows the
system-wide copy `sudo cmake --install` writes. If an edit seems to have no
effect, that shadow is the first thing to check.

### Polling and state

The progress bar ticks locally every 1s; network polls only exist to catch
changes made on other devices. Intervals: 5s popup open, 15s playing/collapsed,
30s paused or idle, plus an immediate poll when a track ends.

`sendPlaybackCommand` sets `refreshBurst = 6`, which drives a 350ms re-poll
timer until the reported state moves or the burst runs out (~2s) — Spotify's
player state lags the command. Change detection compares `trackName|isPlaying`
**plus** a progress-jumped-backwards check, because repeat-one and duplicate
playlist entries skip to a same-titled track and look unchanged otherwise
(`main.qml:249`).

### Panel visibility

`Plasmoid.status: HiddenStatus` alone only hides system-tray items, so the
compact representation also clamps its `Layout.*Width` to 0 when `root.idle`.
`idle` is deliberately false when unconfigured or on wallet error — otherwise
there is no way to right-click the widget to fix it.

`compactRepresentation` sizes itself from the labels' `implicitWidth` (their
natural width, independent of the width given to them) rather than a
`fillWidth`-inside-`implicitWidth` layout, which would feed back into itself.
