# AGENTS.md

## Commands

```bash
python3 setup_auth.py --selftest                                  # only test suite (callback-parsing asserts)
kpackagetool6 --type Plasma/Applet --install spotify-widget/      # first install
kpackagetool6 --type Plasma/Applet --upgrade spotify-widget/      # after editing QML
plasmashell --replace &                                           # reload Plasma to pick up changes
kwallet-query -f 'Spotify Widget' -r refreshToken kdewallet       # inspect stored secrets
```

Widget `console.log`/`console.error` output goes to the `plasmashell` journal:
`journalctl --user -f -t plasmashell`.

## Quality gates

Run these before committing anything you touched. All three are non-zero on
failure, so they chain with `&&`.

```bash
python3 -m py_compile setup_auth.py                        # Python syntax (same parse as ast.parse)
python3 setup_auth.py --selftest                           # callback-parsing asserts
./qmllint.sh spotify-widget/contents/ui/main.qml           # and any other .qml you edited
```

Notes:

- `py_compile` is the no-shell-quoting form of an `ast.parse` check; its
  bytecode lands in the gitignored `__pycache__/`. There is no formatter or
  linter for the Python — syntax and the selftest are the whole bar.
- `qmllint.sh` wraps Qt6's `qmllint`, whose binary name differs by distro. Never
  call plain `qmllint` directly. It is the only QML check there is; there is no
  build step, so a typo otherwise surfaces as a silently blank widget. It exits
  non-zero on real errors and 0 on warnings, so **read the output**, not just
  the status. The baseline is clean — any warning is yours.

## Architecture

Two pieces, no shared code:

- `setup_auth.py` — one-time OAuth dance (stdlib only). Runs a loopback HTTP
  server on `127.0.0.1:8888`, does PKCE + state verification, exchanges the
  code, and writes `clientSecret` + `refreshToken` into KWallet.
- `spotify-widget/` — the Plasma 6 applet. All logic lives in
  [main.qml](spotify-widget/contents/ui/main.qml); the config pages are trivial.

### Credential flow

Only the non-secret Client ID lives in the plasmoid config (`main.xml`). The
client secret and refresh token live in KWallet, folder **Spotify Widget**,
wallet **kdewallet**, and the widget **only ever reads** them.

That read-only property is why the client secret is used at all despite PKCE:
secret-authenticated refresh keeps the refresh token stable. Pure PKCE rotates
it on every renewal, which would force the widget to _write_ to KWallet — and
QML can only reach `kwallet-query` through a shell, where a written value shows
up in the process list. If you change the auth model, that constraint is the
thing to reason about first. `main.qml:135` warns loudly if Spotify rotates the
token anyway.

There is deliberately **no plaintext fallback**: if the wallet is locked or
empty, the widget shows an error and does nothing. Don't add one.

KWallet is reached via a `Plasma5Support.DataSource` with
`engine: "executable"`. Two gotchas encoded in `main.qml:86`: `kwallet-query`
prints errors on _stdout_ and signals failure only through the exit code, so
never trust stdout alone; and the executable engine caches results, so each
source must `disconnectSource()` after the first `onNewData`.

### Polling and state

The progress bar ticks locally every 1s; network polls only exist to catch
changes made on other devices. Intervals: 5s popup open, 15s playing/collapsed,
30s paused or idle, plus an immediate poll when a track ends.

`sendPlaybackCommand` sets `refreshBurst = 6`, which drives a 350ms re-poll
timer until the reported state moves or the burst runs out (~2s) — Spotify's
player state lags the command. Change detection compares `trackName|isPlaying`
**plus** a progress-jumped-backwards check, because repeat-one and duplicate
playlist entries skip to a same-titled track and look unchanged otherwise
(`main.qml:262`).

### Panel visibility

`Plasmoid.status: HiddenStatus` alone only hides system-tray items, so the
compact representation also clamps its `Layout.*Width` to 0 when `root.idle`.
`idle` is deliberately false when unconfigured or on wallet error — otherwise
there is no way to right-click the widget to fix it.

`compactRepresentation` sizes itself from the labels' `implicitWidth` (their
natural width, independent of the width given to them) rather than a
`fillWidth`-inside-`implicitWidth` layout, which would feed back into itself.
