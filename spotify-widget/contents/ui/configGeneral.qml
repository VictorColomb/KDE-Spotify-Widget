import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.private.spotifywidget.wallet

ColumnLayout {
    id: generalConfigPage

    // cfg_ properties are automatically synced with main.xml config keys
    property alias cfg_clientId: clientIdField.text

    spacing: Kirigami.Units.smallSpacing

    Kirigami.FormLayout {
        Layout.fillWidth: true

        QQC2.TextField {
            id: clientIdField
            Kirigami.FormData.label: "Client ID:"
            Layout.fillWidth: true
            placeholderText: "Paste your Spotify Client ID here"
        }

    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        type: Kirigami.MessageType.Information
        visible: true
        // The wallet is whichever one KWallet calls this user's local one, so
        // name it rather than sending people looking in the wrong place.
        text: "Run <b>python3 setup_auth.py</b> in a terminal first — it stores your " +
              "refresh token in <b>KWallet</b> (wallet <i>" + Wallet.localWalletName() +
              "</i>, folder <i>Spotify Widget</i>) and prints the Client ID to paste " +
              "above. Add <b>http://127.0.0.1:8888/callback</b> as a Redirect URI in " +
              "your Spotify Developer Dashboard app settings before running it."
    }
}
