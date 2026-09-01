/*
    SPDX-FileCopyrightText: 2026 Victor Colomb

    SPDX-License-Identifier: MIT
*/

#pragma once

#include <QJSValue>
#include <QList>
#include <QObject>
#include <QQmlEngine>
#include <QString>

namespace KWallet
{
class Wallet;
}

/**
 * KWallet for QML. KF6 ships no QML bindings for KWallet, only the C++ library
 * and the kwallet-query CLI; this is the thinnest wrapper that lets a plasmoid
 * both read and write without going through a shell.
 *
 * Every call takes a JavaScript callback and every callback is invoked exactly
 * once, asynchronously — including when the wallet is already open, so no call
 * site has to cope with both same-tick and later delivery. A callback's `error`
 * is an empty string on success and a sentence fit to show the user otherwise.
 */
class WalletBridge : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Wallet)
    QML_SINGLETON

public:
    explicit WalletBridge(QObject *parent = nullptr);
    ~WalletBridge() override;

    /** The wallet this user actually stores local secrets in. */
    Q_INVOKABLE QString localWalletName() const;

    /** callback(value, error) */
    Q_INVOKABLE void read(const QString &folder, const QString &key, const QJSValue &callback);

    /** callback(error) */
    Q_INVOKABLE void write(const QString &folder, const QString &key, const QString &value, const QJSValue &callback);

private:
    enum class Type {
        Read,
        Write,
    };

    enum class State {
        Closed,
        Opening,
        Open,
    };

    struct Request {
        Type type;
        QString folder;
        QString key;
        QString value;
        QJSValue callback;
    };

    void enqueue(Request &&request);
    void ensureOpen();
    void onWalletOpened(bool success);
    void forgetWallet();
    void flushQueue();
    void failQueue(const QString &error);
    void runRequest(const Request &request);

    static void deliver(const QJSValue &callback, const QJSValueList &args);

    KWallet::Wallet *m_wallet = nullptr;
    State m_state = State::Closed;
    QString m_walletName;
    QList<Request> m_queue;
    bool m_flushScheduled = false;
};
