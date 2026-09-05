/*
    SPDX-FileCopyrightText: 2026 Victor Colomb

    SPDX-License-Identifier: MIT
*/

#pragma once

#include <QObject>
#include <QQmlEngine>

class QTcpServer;
class QTimer;

/**
 * A one-shot loopback HTTP listener for the Spotify OAuth redirect. QML/JS
 * has no socket API, so this is what lets the widget receive the `code`/
 * `state` query string with no copy-paste and no separate script — a C++
 * port of setup_auth.py's `_CallbackHandler`/`_parse_callback`.
 *
 * listen(port) starts listening; callbackReceived(code, state, error) fires
 * exactly once per listen() call — for the first request received, a bind
 * failure, or the ~2 minute timeout — after which the server stops itself.
 * The state check against whatever value the caller generated is QML's job,
 * same as building the authorize URL and exchanging the code; this class
 * only moves bytes.
 */
class OAuthCallback : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(OAuthCallback)
    QML_SINGLETON

public:
    explicit OAuthCallback(QObject *parent = nullptr);
    ~OAuthCallback() override;

    /** Starts listening on 127.0.0.1:port, restarting if already listening. */
    Q_INVOKABLE void listen(int port);

    /** Stops listening without emitting callbackReceived (e.g. dialog closed). */
    Q_INVOKABLE void stop();

    /**
     * Cryptographically-random base64url string of byteLength random bytes —
     * QML/JS has no secure RNG, so this backs both the PKCE verifier and the
     * `state` param. Mirrors setup_auth.py's secrets.token_bytes()/token_urlsafe().
     */
    Q_INVOKABLE QString randomToken(int byteLength) const;

    /** The S256 PKCE code_challenge for a verifier: base64url(sha256(verifier)). */
    Q_INVOKABLE QString pkceChallenge(const QString &verifier) const;

Q_SIGNALS:
    void callbackReceived(const QString &code, const QString &state, const QString &error);

private:
    void handleNewConnection();
    void finish(const QString &code, const QString &state, const QString &error);

    QTcpServer *m_server = nullptr;
    QTimer *m_timeout = nullptr;
};
