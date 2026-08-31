// Lets the compact/full representations reference `root` by id — without it
// every such access is an unqualified-lookup warning.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    // ── Config ──────────────────────────────────────────────────────────────
    // Only the Client ID lives in the plasmoid config — it identifies the app
    // but grants nothing. The secret and refresh token come from KWallet.
    readonly property string clientId: Plasmoid.configuration.clientId

    // ── Credentials from KWallet ────────────────────────────────────────────
    property string clientSecret: ""
    property string refreshToken: ""
    property string walletError:  ""
    readonly property bool credentialsReady: clientSecret !== "" && refreshToken !== ""

    // ── OAuth state ─────────────────────────────────────────────────────────
    property string accessToken:    ""
    property int    tokenExpiresAt: 0   // epoch seconds

    // ── Currently-playing state ─────────────────────────────────────────────
    property string trackName:   "Not playing"
    property string artistName:  ""
    property string albumArtUrl: ""
    property int    progressMs:  0
    property int    durationMs:  1
    property bool   isPlaying:   false
    property bool   hasTrack:    false

    // Follow-up polling after a playback command (see sendPlaybackCommand)
    property int    refreshBurst:       0
    property string preCommandState:    ""
    property int    preCommandProgress: 0

    // Collapse out of the panel only when everything is working and Spotify
    // simply has nothing loaded. If the widget is unconfigured or KWallet
    // failed, stay visible — otherwise there is no way to right-click it.
    readonly property bool idle: credentialsReady && walletError === "" && !hasTrack

    Plasmoid.status: idle ? PlasmaCore.Types.HiddenStatus
                          : PlasmaCore.Types.ActiveStatus

    // ── Helpers ─────────────────────────────────────────────────────────────
    function nowSeconds() {
        return Math.floor(Date.now() / 1000)
    }

    function tokenIsValid() {
        return accessToken !== "" && nowSeconds() < tokenExpiresAt - 30
    }

    // Identity of what is on screen, used to tell whether a playback command
    // has actually taken effect yet.
    function playbackState() {
        return trackName + "|" + isPlaying
    }

    function formatTime(ms) {
        var s = Math.floor(ms / 1000)
        return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2)
    }

    // ── KWallet ─────────────────────────────────────────────────────────────
    // There is no QML binding for KWallet, so we shell out to kwallet-query.
    // Reads only: the value comes back on stdout and never touches a command
    // line. Nothing is ever written from here, and there is no config-file
    // fallback — if the wallet is locked or missing, the widget stays dark.
    readonly property string walletName:   "kdewallet"
    readonly property string walletFolder: "Spotify Widget"

    function walletReadCmd(key) {
        return "kwallet-query -f '" + walletFolder + "' -r " + key + " " + walletName
    }

    Plasma5Support.DataSource {
        id: wallet
        engine: "executable"
        connectedSources: []

        onNewData: function(source, data) {
            disconnectSource(source)   // one-shot; the engine caches otherwise

            // kwallet-query prints its errors on stdout and signals failure
            // only through the exit code, so never trust stdout on its own.
            var code   = data["exit code"]
            var value  = (data["stdout"] || "").trim()
            var isSecret = (source === root.walletReadCmd("clientSecret"))
            var keyName  = isSecret ? "clientSecret" : "refreshToken"

            if (code !== 0 || value === "") {
                root.walletError = "Could not read " + keyName + " from KWallet"
                                 + " (exit " + code + "). Is the wallet unlocked?"
                console.error("Spotify Widget:", root.walletError, value)
                return
            }

            if (isSecret) root.clientSecret = value
            else          root.refreshToken = value
        }
    }

    function loadCredentials() {
        walletError  = ""
        clientSecret = ""
        refreshToken = ""
        wallet.connectSource(walletReadCmd("clientSecret"))
        wallet.connectSource(walletReadCmd("refreshToken"))
    }

    // ── Token management ────────────────────────────────────────────────────
    function refreshAccessToken(callback) {
        if (!clientId || !credentialsReady) {
            console.warn("Spotify Widget: credentials not configured")
            return
        }
        var xhr = new XMLHttpRequest()
        xhr.open("POST", "https://accounts.spotify.com/api/token")
        xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded")
        xhr.setRequestHeader("Authorization", "Basic " + Qt.btoa(clientId + ":" + clientSecret))
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                var data = JSON.parse(xhr.responseText)
                accessToken    = data.access_token
                tokenExpiresAt = nowSeconds() + data.expires_in
                // Secret-authenticated refresh keeps the token stable, which is
                // why we can stay read-only. If Spotify ever rotates it anyway,
                // say so loudly rather than silently expiring days later.
                if (data.refresh_token && data.refresh_token !== refreshToken) {
                    walletError = "Spotify rotated the refresh token. "
                                + "Re-run setup_auth.py to store the new one."
                    console.warn("Spotify Widget:", walletError)
                }
                if (callback) callback()
            } else {
                console.error("Spotify Widget: token refresh failed", xhr.status, xhr.responseText)
            }
        }
        xhr.send(
            "grant_type=refresh_token" +
            "&refresh_token=" + encodeURIComponent(refreshToken)
        )
    }

    // Ensures a valid token then invokes callback()
    function withToken(callback) {
        if (tokenIsValid()) {
            callback()
        } else {
            refreshAccessToken(callback)
        }
    }

    // ── Spotify API ──────────────────────────────────────────────────────────
    function fetchCurrentlyPlaying() {
        withToken(function() {
            var xhr = new XMLHttpRequest()
            xhr.open("GET", "https://api.spotify.com/v1/me/player/currently-playing")
            xhr.setRequestHeader("Authorization", "Bearer " + accessToken)
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== XMLHttpRequest.DONE) return
                if (xhr.status === 200) {
                    var data = JSON.parse(xhr.responseText)
                    if (data && data.item) {
                        trackName  = data.item.name
                        artistName = data.item.artists.map(function(a) { return a.name }).join(", ")
                        progressMs = data.progress_ms || 0
                        durationMs = data.item.duration_ms || 1
                        isPlaying  = data.is_playing
                        hasTrack   = true
                        var imgs = data.item.album && data.item.album.images
                        if (imgs && imgs.length > 0) {
                            // Prefer medium image (~300px) when available
                            albumArtUrl = imgs[imgs.length > 1 ? 1 : 0].url
                        }
                    }
                } else if (xhr.status === 204) {
                    // Nothing currently playing
                    trackName   = "Not playing"
                    artistName  = ""
                    isPlaying   = false
                    hasTrack    = false
                    albumArtUrl = ""
                } else if (xhr.status === 401) {
                    // Token expired mid-poll — clear so next cycle forces refresh
                    accessToken = ""
                }
            }
            xhr.send()
        })
    }

    function sendPlaybackCommand(method, endpoint, body) {
        withToken(function() {
            var xhr = new XMLHttpRequest()
            xhr.open(method, "https://api.spotify.com/v1/me/player/" + endpoint)
            xhr.setRequestHeader("Authorization", "Bearer " + accessToken)
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== XMLHttpRequest.DONE) return
                // Spotify's player state lags the command, so a single re-poll
                // often still returns the previous track. Re-check a few times
                // and stop as soon as the state actually moves.
                root.preCommandState    = root.playbackState()
                root.preCommandProgress = root.progressMs
                root.refreshBurst       = 6
            }
            if (body !== null) {
                xhr.setRequestHeader("Content-Type", "application/json")
                xhr.send(JSON.stringify(body))
            } else {
                xhr.send()
            }
        })
    }

    // ── Timers ───────────────────────────────────────────────────────────────

    // Poll currently-playing. The progress bar ticks locally, so polling only
    // needs to catch changes made elsewhere (phone, other device) — rare enough
    // that hammering the API every 2s buys nothing.
    Timer {
        id: pollTimer
        interval: !root.isPlaying   ? 30000   // paused/idle: nothing to track
                : root.expanded     ? 5000    // popup open: someone is watching
                                    : 15000   // playing, collapsed
        running:  root.credentialsReady
        repeat:   true
        triggeredOnStart: true
        onTriggered: root.fetchCurrentlyPlaying()
    }

    // Smooth progress tick between polls
    Timer {
        interval: 1000
        running:  root.isPlaying
        repeat:   true
        onTriggered: {
            if (root.progressMs + 1000 <= root.durationMs) {
                root.progressMs += 1000
            } else {
                // Track just ended — the next one started, so poll now instead
                // of waiting out the interval.
                root.fetchCurrentlyPlaying()
            }
        }
    }

    // After a playback command, re-poll every 350ms until the reported state
    // differs from what it was when the command landed, or the burst runs out
    // (~2s). Bounded, so a failed command cannot leave this spinning.
    Timer {
        id: refreshDelay
        interval: 350
        repeat:   true
        running:  root.refreshBurst > 0
        onTriggered: {
            // Track name is not a unique identity: repeat-one, a duplicate in a
            // playlist, or an album reprise all skip to a same-titled track and
            // look unchanged. Progress resetting is the only signal there. The
            // 2s slack absorbs drift between the local tick and the server.
            var jumped = root.progressMs < root.preCommandProgress - 2000

            if (root.playbackState() !== root.preCommandState || jumped) {
                root.refreshBurst = 0   // state moved; the regular poll takes over
                return
            }
            root.refreshBurst--
            root.fetchCurrentlyPlaying()
        }
    }

    // ── Compact representation (panel) ───────────────────────────────────────
    // Album art with a progress underline, then bold track over dimmed artist.
    compactRepresentation: MouseArea {
        id: compactRoot

        readonly property int gap: Kirigami.Units.smallSpacing

        // Full panel thickness — the panel already insets its contents.
        readonly property int artSize: Math.max(16, height)

        // Widest the text column may get before eliding.
        readonly property int maxTextWidth: 190

        // Driven by the labels' *natural* widths, which do not depend on the
        // width they are given — so this cannot feed back into itself the way
        // a fillWidth-inside-implicitWidth layout does.
        readonly property int textWidth: Math.min(maxTextWidth,
                                                  Math.ceil(Math.max(trackLabel.implicitWidth,
                                                                     artistLabel.implicitWidth)))
        readonly property int fullWidth: artSize + gap + textWidth + gap

        // Zero-width when idle: Plasmoid.status alone only hides system-tray
        // items, so a panel applet has to collapse itself.
        Layout.minimumWidth:   root.idle ? 0 : fullWidth
        Layout.preferredWidth: root.idle ? 0 : fullWidth
        Layout.maximumWidth:   root.idle ? 0 : fullWidth
        visible: !root.idle

        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        // -- Album art + progress underline --
        Item {
            id: artHolder
            anchors.left:           parent.left
            anchors.verticalCenter: parent.verticalCenter
            width:  compactRoot.artSize
            height: compactRoot.artSize

            Image {
                anchors.fill: parent
                source:       root.albumArtUrl
                fillMode:     Image.PreserveAspectCrop
                visible:      root.albumArtUrl !== ""
                asynchronous: true
            }

            Kirigami.Icon {
                anchors.fill: parent
                source:  "media-optical-audio"
                opacity: 0.5
                visible: root.albumArtUrl === ""
            }
        }

        // -- Track over artist --
        Column {
            anchors.left:           artHolder.right
            anchors.leftMargin:     compactRoot.gap
            anchors.verticalCenter: parent.verticalCenter
            width:   compactRoot.textWidth
            spacing: 0

            QQC2.Label {
                id: trackLabel
                width:     parent.width
                text:      root.trackName
                font.bold: true
                font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.85
                elide:     Text.ElideRight
                maximumLineCount: 1
            }

            QQC2.Label {
                id: artistLabel
                width:     parent.width
                text:      root.artistName
                opacity:   0.7
                font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.75
                elide:     Text.ElideRight
                maximumLineCount: 1
                visible:   text !== ""
            }
        }
    }

    // ── Full / desktop representation ────────────────────────────────────────
    fullRepresentation: ColumnLayout {
        id: fullView

        // Cover size doubles as the width for the progress bar and timestamps.
        readonly property int artSize: 280
        readonly property int margin: Kirigami.Units.largeSpacing
        readonly property int popupWidth: artSize + 2 * margin

        // Plasma sizes the popup from these, not from `width` — without them it
        // falls back to a ~25 grid-unit default, far wider than the content.
        Layout.minimumWidth:    popupWidth
        Layout.preferredWidth:  popupWidth
        Layout.maximumWidth:    popupWidth
        Layout.preferredHeight: implicitHeight

        spacing: Kirigami.Units.smallSpacing

        // -- KWallet failure: hard stop, there is no fallback --
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            type:    Kirigami.MessageType.Error
            visible: root.walletError !== ""
            text:    root.walletError
        }

        // -- Unconfigured notice --
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            type:    Kirigami.MessageType.Warning
            visible: root.walletError === "" && !root.credentialsReady
            text:    "Run <b>setup_auth.py</b>, then right-click → Configure to add your Client ID."
        }

        // -- Album art --
        Item {
            Layout.alignment:       Qt.AlignHCenter
            Layout.topMargin:       fullView.margin
            Layout.preferredWidth:  fullView.artSize
            Layout.preferredHeight: fullView.artSize

            Image {
                id: albumArt
                anchors.fill: parent
                source:       root.albumArtUrl
                fillMode:     Image.PreserveAspectFit
                visible:      root.albumArtUrl !== ""
            }

            // Placeholder when no album art
            Rectangle {
                anchors.fill: parent
                color:        Kirigami.Theme.alternateBackgroundColor
                radius:       8
                visible:      root.albumArtUrl === ""

                Kirigami.Icon {
                    source: "media-optical-audio"
                    anchors.centerIn: parent
                    width:  80
                    height: 80
                    opacity: 0.4
                }
            }
        }

        // -- Track name --
        QQC2.Label {
            text:                root.trackName
            font.bold:           true
            wrapMode:            Text.WordWrap
            Layout.fillWidth:    true
            horizontalAlignment: Text.AlignHCenter
            elide:               Text.ElideRight
            maximumLineCount:    2
        }

        // -- Artist name --
        QQC2.Label {
            text:                root.artistName
            opacity:             0.7
            Layout.fillWidth:    true
            horizontalAlignment: Text.AlignHCenter
            elide:               Text.ElideRight
        }

        // -- Progress bar + timestamps, matched to the cover width --
        QQC2.ProgressBar {
            from:                  0
            to:                    root.durationMs
            value:                 root.progressMs
            Layout.alignment:      Qt.AlignHCenter
            Layout.preferredWidth: fullView.artSize
        }

        RowLayout {
            // A nested layout defaults to fillWidth: true, which would stretch
            // this to the popup width and ignore the alignment below.
            Layout.fillWidth:      false
            Layout.alignment:      Qt.AlignHCenter
            Layout.preferredWidth: fullView.artSize

            QQC2.Label {
                text:      root.formatTime(root.progressMs)
                font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.75
            }
            Item { Layout.fillWidth: true }
            QQC2.Label {
                text:      root.formatTime(root.durationMs)
                font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.75
            }
        }

        // -- Playback controls --
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing:          Kirigami.Units.largeSpacing

            QQC2.ToolButton {
                icon.name: "media-skip-backward"
                onClicked: root.sendPlaybackCommand("POST", "previous", null)
            }

            QQC2.ToolButton {
                icon.name: root.isPlaying ? "media-playback-pause"
                                          : "media-playback-start"
                onClicked: {
                    if (root.isPlaying) {
                        root.sendPlaybackCommand("PUT", "pause", null)
                    } else {
                        root.sendPlaybackCommand("PUT", "play", null)
                    }
                }
            }

            QQC2.ToolButton {
                icon.name: "media-skip-forward"
                onClicked: root.sendPlaybackCommand("POST", "next", null)
            }
        }

        Item { Layout.preferredHeight: fullView.margin }
    }

    // Both wallet reads land asynchronously; start once we have the pair.
    onCredentialsReadyChanged: {
        if (credentialsReady) {
            accessToken = ""
            withToken(function() { root.fetchCurrentlyPlaying() })
        }
    }

    Component.onCompleted: root.loadCredentials()

    // Re-read the wallet when the Client ID changes (i.e. after setup)
    Connections {
        target: Plasmoid.configuration
        function onClientIdChanged() {
            root.loadCredentials()
        }
    }
}
