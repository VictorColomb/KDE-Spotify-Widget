#!/bin/sh
# Finds Qt6's qmllint, wherever the distro hid it, and runs it on "$@".
#
# Fedora exposes it directly as `qmllint-qt6`. Arch's `qmllint` on PATH is
# Qt5's (from qt5-declarative) and crashes on the Qt6-only pragma
# `ComponentBehavior: Bound`; Arch's actual Qt6 binary (from qt6-declarative,
# usually already installed alongside Plasma 6) ships unlisted at
# /usr/lib/qt6/bin/qmllint. Debian/Ubuntu (package qt6-declarative-dev-tools)
# install it at that same /usr/lib/qt6/bin/qmllint path and don't put an
# unversioned qmllint on PATH at all, so they hit no shadowing trap either.
set -e

# The widget imports org.kde.private.spotifywidget.wallet, which only exists
# once CMake has built it. ECM mirrors the module into build/bin, so point
# qmllint there rather than having it report the import unresolved.
imports=""
build_qml="$(dirname "$0")/build/bin"
if [ -d "$build_qml" ]; then
    imports="-I $build_qml"
fi

# Extra flags (e.g. --bare, to diagnose a stale system-wide install shadowing
# build/bin — see AGENTS.md) pass straight through via "$@" onto whichever
# real Qt6 binary we found, same as any other qmllint argument.
for candidate in qmllint-qt6 qmllint6 /usr/lib/qt6/bin/qmllint; do
    if command -v "$candidate" >/dev/null 2>&1; then
        exec "$candidate" $imports "$@"
    fi
done

# Last resort: whatever `qmllint` resolves to, if it's actually Qt6.
if command -v qmllint >/dev/null 2>&1 && qmllint --version 2>&1 | grep -q ' 6\.'; then
    exec qmllint $imports "$@"
fi

echo "qmllint: no Qt6 qmllint found (checked qmllint-qt6, qmllint6, /usr/lib/qt6/bin/qmllint, qmllint)." >&2
exit 127
