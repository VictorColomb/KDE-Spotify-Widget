/*
    SPDX-FileCopyrightText: 2026 Victor Colomb

    SPDX-License-Identifier: MIT
*/

#include "httpbridge.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrl>

HttpBridge::HttpBridge(QObject *parent)
    : QObject(parent)
    , m_nam(new QNetworkAccessManager(this))
{
}

void HttpBridge::deleteJson(const QString &url, const QString &bearerToken, const QString &jsonBody, const QJSValue &callback)
{
    const QUrl target(url);
    if (target.scheme() != QLatin1String("https") || target.host() != QLatin1String("api.spotify.com")) {
        // Deferred like every other callback in this plugin.
        QMetaObject::invokeMethod(
            this,
            [callback]() mutable {
                if (callback.isCallable()) {
                    callback.call({QJSValue(0), QJSValue(QStringLiteral("Refused: not api.spotify.com."))});
                }
            },
            Qt::QueuedConnection);
        return;
    }

    QNetworkRequest request(target);
    request.setRawHeader("Authorization", "Bearer " + bearerToken.toUtf8());
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));

    QNetworkReply *reply = m_nam->sendCustomRequest(request, "DELETE", jsonBody.toUtf8());
    connect(reply, &QNetworkReply::finished, this, [reply, callback]() mutable {
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QString text = QString::fromUtf8(reply->readAll());
        reply->deleteLater();
        if (callback.isCallable()) {
            callback.call({QJSValue(status), QJSValue(text)});
        }
    });
}
