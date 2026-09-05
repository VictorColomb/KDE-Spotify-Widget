/*
    SPDX-FileCopyrightText: 2026 Victor Colomb

    SPDX-License-Identifier: MIT
*/

#include "oauthcallback.h"

#include <QCryptographicHash>
#include <QRandomGenerator>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>

namespace
{
// Mirrors setup_auth.py's thread.join(timeout=120): don't listen forever if
// the user never completes (or abandons) the browser dance.
constexpr int TimeoutMs = 120000;

QByteArray responsePage(bool success)
{
    return success ? QByteArrayLiteral("<html><body><h2>Authorization successful!</h2>"
                                        "<p>You can close this tab.</p></body></html>")
                   : QByteArrayLiteral("<html><body><h2>Authorization failed.</h2>"
                                        "<p>Check the widget for details.</p></body></html>");
}
}

OAuthCallback::OAuthCallback(QObject *parent)
    : QObject(parent)
{
}

OAuthCallback::~OAuthCallback() = default;

void OAuthCallback::listen(int port)
{
    stop();

    m_server = new QTcpServer(this);
    connect(m_server, &QTcpServer::newConnection, this, &OAuthCallback::handleNewConnection);

    if (!m_server->listen(QHostAddress::LocalHost, static_cast<quint16>(port))) {
        const QString error = m_server->errorString();
        stop();
        finish(QString(), QString(), QStringLiteral("Could not listen on 127.0.0.1:%1 — %2").arg(port).arg(error));
        return;
    }

    m_timeout = new QTimer(this);
    m_timeout->setSingleShot(true);
    connect(m_timeout, &QTimer::timeout, this, [this] {
        stop();
        finish(QString(), QString(), QStringLiteral("Timed out waiting for the Spotify redirect (2 minutes)."));
    });
    m_timeout->start(TimeoutMs);
}

void OAuthCallback::stop()
{
    if (m_timeout) {
        m_timeout->stop();
        m_timeout->deleteLater();
        m_timeout = nullptr;
    }
    if (m_server) {
        m_server->close();
        m_server->deleteLater();
        m_server = nullptr;
    }
}

void OAuthCallback::handleNewConnection()
{
    QTcpSocket *socket = m_server->nextPendingConnection();
    if (!socket) {
        return;
    }
    // nextPendingConnection() parents the socket to the server; reparent it
    // before stop() deletes the server, or the socket dies with it.
    socket->setParent(this);

    // One request is all we want; stop accepting more before we even parse
    // it, so a stray second connection cannot race the first.
    stop();

    connect(socket, &QTcpSocket::readyRead, this, [this, socket] {
        // The request line is all we need; wait for its terminating CRLF
        // rather than trying to parse a partial read.
        if (!socket->bytesAvailable() || !socket->peek(socket->bytesAvailable()).contains("\r\n")) {
            return;
        }

        const QByteArray requestLine = socket->readLine();
        // "GET /callback?code=...&state=... HTTP/1.1"
        const QList<QByteArray> parts = requestLine.split(' ');
        const QString path = parts.size() >= 2 ? QString::fromUtf8(parts.at(1)) : QString();
        const QUrlQuery query(QUrl(path).query());

        QString code, state, error;
        state = query.queryItemValue(QStringLiteral("state"), QUrl::FullyDecoded);
        if (query.hasQueryItem(QStringLiteral("error"))) {
            error = query.queryItemValue(QStringLiteral("error"), QUrl::FullyDecoded);
        } else if (query.hasQueryItem(QStringLiteral("code"))) {
            code = query.queryItemValue(QStringLiteral("code"), QUrl::FullyDecoded);
        } else {
            error = QStringLiteral("callback had neither code nor error");
        }

        const QByteArray body = responsePage(error.isEmpty());
        socket->write("HTTP/1.1 200 OK\r\n"
                       "Content-Type: text/html; charset=utf-8\r\n"
                       "Content-Length: "
                       + QByteArray::number(body.size())
                       + "\r\n"
                         "Connection: close\r\n\r\n"
                       + body);
        socket->disconnectFromHost();

        finish(code, state, error);
    });
    connect(socket, &QTcpSocket::disconnected, socket, &QTcpSocket::deleteLater);
}

void OAuthCallback::finish(const QString &code, const QString &state, const QString &error)
{
    Q_EMIT callbackReceived(code, state, error);
}

QString OAuthCallback::randomToken(int byteLength) const
{
    QByteArray bytes(byteLength, '\0');
    for (char &b : bytes) {
        b = static_cast<char>(QRandomGenerator::system()->bounded(256));
    }
    return QString::fromLatin1(bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
}

QString OAuthCallback::pkceChallenge(const QString &verifier) const
{
    const QByteArray digest = QCryptographicHash::hash(verifier.toUtf8(), QCryptographicHash::Sha256);
    return QString::fromLatin1(digest.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
}
