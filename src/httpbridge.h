/*
    SPDX-FileCopyrightText: 2026 Victor Colomb

    SPDX-License-Identifier: MIT
*/

#pragma once

#include <QJSValue>
#include <QObject>
#include <QQmlEngine>

class QNetworkAccessManager;

/**
 * QML's XMLHttpRequest silently drops the body of a DELETE, and Spotify's
 * "remove playlist items" needs one. This sends exactly that request and
 * nothing else — it only ever talks to api.spotify.com, because QML singletons
 * are shared shell-wide and this carries a bearer token.
 */
class HttpBridge : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Http)
    QML_SINGLETON

public:
    explicit HttpBridge(QObject *parent = nullptr);

    /** callback(status, responseText); status is 0 on a network error or a refused URL. */
    Q_INVOKABLE void deleteJson(const QString &url, const QString &bearerToken, const QString &jsonBody, const QJSValue &callback);

private:
    QNetworkAccessManager *m_nam = nullptr;
};
