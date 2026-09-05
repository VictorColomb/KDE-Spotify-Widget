/*
    SPDX-FileCopyrightText: 2026 Victor Colomb

    SPDX-License-Identifier: MIT
*/

#include "walletbridge.h"

#include <KWallet>

#include <QDebug>

using KWallet::Wallet;

WalletBridge::WalletBridge(QObject *parent)
    : QObject(parent)
{
}

WalletBridge::~WalletBridge()
{
    delete m_wallet;
}

QString WalletBridge::localWalletName() const
{
    return Wallet::LocalWallet();
}

void WalletBridge::read(const QString &folder, const QString &key, const QJSValue &callback)
{
    enqueue({Type::Read, folder, key, QString(), callback});
}

void WalletBridge::write(const QString &folder, const QString &key, const QString &value, const QJSValue &callback)
{
    enqueue({Type::Write, folder, key, value, callback});
}

void WalletBridge::enqueue(Request &&request)
{
    m_queue.append(std::move(request));
    ensureOpen();
}

void WalletBridge::ensureOpen()
{
    if (m_state == State::Opening) {
        return; // the pending walletOpened() will drain the queue
    }

    if (m_state == State::Open) {
        // Deferred even though we could serve it right now, so that a callback
        // never fires before the read()/write() call has returned.
        if (!m_flushScheduled) {
            m_flushScheduled = true;
            QMetaObject::invokeMethod(
                this,
                [this] {
                    m_flushScheduled = false;
                    flushQueue();
                },
                Qt::QueuedConnection);
        }
        return;
    }

    m_walletName = localWalletName();

    // Asynchronous is not an optimisation here: the synchronous variant blocks
    // until kwalletd answers, and if the wallet is locked that means blocking
    // across a password prompt. On plasmashell's GUI thread that freezes the
    // entire panel.
    m_wallet = Wallet::openWallet(m_walletName, 0, Wallet::Asynchronous);

    if (!m_wallet) {
        failQueue(QStringLiteral("KWallet is unavailable — could not start opening wallet \"%1\".").arg(m_walletName));
        return;
    }

    m_state = State::Opening;
    connect(m_wallet, &Wallet::walletOpened, this, &WalletBridge::onWalletOpened);
    connect(m_wallet, &Wallet::walletClosed, this, &WalletBridge::forgetWallet);
    connect(m_wallet, &QObject::destroyed, this, [this] {
        m_wallet = nullptr;
        m_state = State::Closed;
    });
}

void WalletBridge::onWalletOpened(bool success)
{
    if (!success) {
        // Back to Closed rather than a terminal failure state: the user may
        // have cancelled the unlock prompt and be willing to retry.
        forgetWallet();
        failQueue(QStringLiteral("Could not open wallet \"%1\". Is KWallet running and unlocked?").arg(m_walletName));
        return;
    }

    m_state = State::Open;
    flushQueue();
}

void WalletBridge::forgetWallet()
{
    m_state = State::Closed;

    if (!m_wallet) {
        return;
    }

    // Cleared before deleteLater() so a request arriving in between opens a
    // fresh wallet instead of adopting one that is on its way out.
    Wallet *closing = m_wallet;
    m_wallet = nullptr;
    closing->disconnect(this);
    closing->deleteLater();
}

void WalletBridge::flushQueue()
{
    // Callbacks run inside runRequest() and may enqueue further requests; the
    // loop picks those up rather than deferring them another round trip.
    while (m_state == State::Open && !m_queue.isEmpty()) {
        runRequest(m_queue.takeFirst());
    }

    if (!m_queue.isEmpty()) {
        ensureOpen(); // the wallet closed under us mid-drain
    }
}

void WalletBridge::failQueue(const QString &error)
{
    const QList<Request> pending = m_queue;
    m_queue.clear();

    for (const Request &request : pending) {
        if (request.type == Type::Read) {
            deliver(request.callback, {QJSValue(QString()), QJSValue(error)});
        } else {
            deliver(request.callback, {QJSValue(error)});
        }
    }
}

void WalletBridge::runRequest(const Request &request)
{
    // readPassword()/writePassword()/setFolder() are synchronous D-Bus calls,
    // but on an already-open wallet they never prompt, so unlike openWallet()
    // they cannot stall the GUI thread on user input.
    const QString where = QStringLiteral("folder \"%1\" of wallet \"%2\"").arg(request.folder, m_walletName);

    if (request.type == Type::Write && !m_wallet->hasFolder(request.folder) && !m_wallet->createFolder(request.folder)) {
        deliver(request.callback, {QJSValue(QStringLiteral("Could not create %1.").arg(where))});
        return;
    }

    if (!m_wallet->setFolder(request.folder)) {
        const QString error =
            QStringLiteral("Wallet \"%1\" has no folder \"%2\".").arg(m_walletName, request.folder);
        if (request.type == Type::Read) {
            deliver(request.callback, {QJSValue(QString()), QJSValue(error)});
        } else {
            deliver(request.callback, {QJSValue(error)});
        }
        return;
    }

    if (request.type == Type::Read) {
        QString value;
        // An entry that exists but is empty is as useless to the caller as a
        // missing one, and no caller stores an empty secret on purpose.
        if (m_wallet->readPassword(request.key, value) != 0 || value.isEmpty()) {
            deliver(request.callback,
                    {QJSValue(QString()), QJSValue(QStringLiteral("KWallet has no \"%1\" entry in %2.").arg(request.key, where))});
        } else {
            deliver(request.callback, {QJSValue(value), QJSValue(QString())});
        }
        return;
    }

    if (m_wallet->writePassword(request.key, request.value) != 0) {
        deliver(request.callback, {QJSValue(QStringLiteral("Could not write \"%1\" to %2.").arg(request.key, where))});
    } else {
        Q_EMIT wroteEntry(request.folder, request.key);
        deliver(request.callback, {QJSValue(QString())});
    }
}

void WalletBridge::deliver(const QJSValue &callback, const QJSValueList &args)
{
    if (!callback.isCallable()) {
        return;
    }

    QJSValue call = callback;
    const QJSValue result = call.call(args);
    if (result.isError()) {
        qWarning() << "Spotify Widget: wallet callback threw" << result.toString();
    }
}
