import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.private.spotifywidget.wallet

ColumnLayout {
    id: generalConfigPage

    // cfg_ properties are automatically synced with main.xml config keys
    property alias cfg_clientId: clientIdField.text

    readonly property string walletFolder: "Spotify Widget"
    readonly property string redirectUri:  "http://127.0.0.1:8888/callback"
    readonly property string scopes:
        "user-read-currently-playing user-read-playback-state user-modify-playback-state"

    // ── Authorize-with-Spotify flow state ───────────────────────────────────
    // A C++ port of setup_auth.py's PKCE dance: generate verifier/state, open
    // the loopback listener and the browser, then exchange the code the same
    // way main.qml's refreshAccessToken() already does.
    property bool   authorizing:     false
    property bool   authFailed:      false
    property string authStatus:      ""
    property string authUrl:         ""
    property string pendingVerifier: ""
    property string pendingState:    ""

    spacing: Kirigami.Units.smallSpacing

    function startAuthorization() {
        authorizing     = true
        authFailed      = false
        authStatus      = "Waiting for Spotify authorization…"
        pendingVerifier = OAuthCallback.randomToken(32)
        pendingState    = OAuthCallback.randomToken(16)

        authUrl = "https://accounts.spotify.com/authorize"
            + "?client_id=" + encodeURIComponent(clientIdField.text)
            + "&response_type=code"
            + "&redirect_uri=" + encodeURIComponent(redirectUri)
            + "&scope=" + encodeURIComponent(scopes)
            + "&state=" + encodeURIComponent(pendingState)
            + "&code_challenge_method=S256"
            + "&code_challenge=" + encodeURIComponent(OAuthCallback.pkceChallenge(pendingVerifier))

        OAuthCallback.listen(8888)
        Qt.openUrlExternally(authUrl)
        // Left displayed as a copy-paste fallback in case openUrlExternally
        // couldn't reach a browser.
    }

    function finishAuthorization(failed, message) {
        authorizing = false
        authFailed  = failed
        authStatus  = message
        if (!failed) {
            authUrl = ""
        }
    }

    function exchangeCode(code) {
        var xhr = new XMLHttpRequest()
        xhr.open("POST", "https://accounts.spotify.com/api/token")
        xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status !== 200) {
                finishAuthorization(true, "Token exchange failed (" + xhr.status + "): " + xhr.responseText)
                return
            }
            var data = JSON.parse(xhr.responseText)
            if (!data.refresh_token) {
                finishAuthorization(true, "Spotify's response had no refresh token.")
                return
            }
            Wallet.write(walletFolder, "refreshToken", data.refresh_token, function(error) {
                if (error !== "") {
                    finishAuthorization(true, error)
                } else {
                    finishAuthorization(false, "Authorized. The widget will pick it up immediately.")
                }
            })
        }
        xhr.send(
            "grant_type=authorization_code" +
            "&code=" + encodeURIComponent(code) +
            "&redirect_uri=" + encodeURIComponent(redirectUri) +
            "&client_id=" + encodeURIComponent(clientIdField.text) +
            "&code_verifier=" + encodeURIComponent(pendingVerifier)
        )
    }

    Connections {
        target: OAuthCallback
        function onCallbackReceived(code, state, error) {
            if (error !== "") {
                generalConfigPage.finishAuthorization(true, "Authorization failed: " + error)
            } else if (state !== generalConfigPage.pendingState) {
                generalConfigPage.finishAuthorization(true, "State mismatch — rejected (possible CSRF, or a stray request).")
            } else {
                generalConfigPage.exchangeCode(code)
            }
        }
    }

    // Dialog closed mid-flow: stop listening rather than leave the port bound.
    Component.onDestruction: OAuthCallback.stop()

    Kirigami.FormLayout {
        Layout.fillWidth: true

        RowLayout {
            Kirigami.FormData.label: "Client ID:"
            Layout.fillWidth: true

            QQC2.TextField {
                id: clientIdField
                Layout.fillWidth: true
                placeholderText: "Paste your Spotify Client ID here"
            }

            QQC2.Button {
                text:    "Authorize with Spotify"
                enabled: clientIdField.text !== "" && !generalConfigPage.authorizing
                onClicked: generalConfigPage.startAuthorization()
            }
        }
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        type:    Kirigami.MessageType.Information
        visible: true
        // The wallet is whichever one KWallet calls this user's local one, so
        // name it rather than sending people looking in the wrong place.
        text: "Add <b>" + generalConfigPage.redirectUri + "</b> as a Redirect URI in your Spotify " +
              "Developer Dashboard app, paste its Client ID above, then click " +
              "<b>Authorize with Spotify</b>. The refresh token goes straight " +
              "into <b>KWallet</b> (wallet <i>" + Wallet.localWalletName() +
              "</i>, folder <i>" + generalConfigPage.walletFolder + "</i>) — nothing else to run."
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        type:    generalConfigPage.authFailed ? Kirigami.MessageType.Error : Kirigami.MessageType.Positive
        visible: generalConfigPage.authStatus !== ""
        text:    generalConfigPage.authStatus
    }

    QQC2.TextField {
        Layout.fillWidth: true
        visible:  generalConfigPage.authUrl !== ""
        readOnly: true
        text:     generalConfigPage.authUrl
        // Fallback for when Qt.openUrlExternally couldn't reach a browser —
        // select-all on focus so a click then Ctrl+C copies the whole URL.
        onActiveFocusChanged: if (activeFocus) selectAll()
    }
}
