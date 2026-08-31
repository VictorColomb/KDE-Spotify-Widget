import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

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
        text: "Run <b>python3 setup_auth.py</b> in a terminal first — it stores your " +
              "client secret and refresh token in <b>KWallet</b> and prints the Client ID " +
              "to paste above. Add <b>http://127.0.0.1:8888/callback</b> as a Redirect URI " +
              "in your Spotify Developer Dashboard app settings before running it."
    }
}
