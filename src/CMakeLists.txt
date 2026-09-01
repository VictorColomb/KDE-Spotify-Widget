ecm_add_qml_module(spotifywidgetwallet
    URI "org.kde.private.spotifywidget.wallet"
    VERSION 1.0
    GENERATE_PLUGIN_SOURCE
    DEPENDENCIES QtQml
)

target_sources(spotifywidgetwallet PRIVATE
    walletbridge.cpp
    walletbridge.h
)

target_link_libraries(spotifywidgetwallet PRIVATE
    Qt6::Qml
    KF6::Wallet
)

# Installs the plugin, its qmldir and its type info under the QML import path.
# No separate install(TARGETS): the plugin *is* the backing target, so adding
# one would drop a second copy of the .so into the library directory.
ecm_finalize_qml_module(spotifywidgetwallet DESTINATION ${KDE_INSTALL_QMLDIR})
