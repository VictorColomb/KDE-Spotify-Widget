cmake_minimum_required(VERSION 3.20)

project(spotify-widget VERSION 1.1 LANGUAGES CXX)

find_package(ECM 6.0 REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

# Queried before KDEInstallDirs, which bakes the prefix into its paths.
include(ECMQueryQt)
ecm_query_qt(QT_INSTALL_PREFIX QT_INSTALL_PREFIX)
ecm_query_qt(QT_INSTALL_QML QT_INSTALL_QML)

# Qt scans only its own QML directory for imports, so the CMake default prefix
# of /usr/local installs a module nothing can import — and a plasmoid whose
# import fails renders as a blank widget with no complaint anywhere. Default to
# Qt's own prefix instead of that trap.
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
    set(CMAKE_INSTALL_PREFIX "${QT_INSTALL_PREFIX}" CACHE PATH
        "Install path prefix, prepended onto install directories." FORCE)
    message(STATUS "No CMAKE_INSTALL_PREFIX given; using Qt's own prefix ${CMAKE_INSTALL_PREFIX}")
endif()

include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)
include(ECMQmlModule)

find_package(Qt6 6.5 REQUIRED COMPONENTS Qml)
find_package(KF6 6.0 REQUIRED COMPONENTS Wallet Package)

# And if the prefix was chosen explicitly, say so rather than letting it fail
# silently at runtime.
if(NOT KDE_INSTALL_FULL_QMLDIR STREQUAL QT_INSTALL_QML)
    message(WARNING
        "QML modules install to ${KDE_INSTALL_FULL_QMLDIR}, but Qt imports from "
        "${QT_INSTALL_QML}. The widget will not find the wallet plugin. Either "
        "reconfigure with -DCMAKE_INSTALL_PREFIX=${QT_INSTALL_PREFIX}, or set "
        "QML_IMPORT_PATH in the environment plasmashell runs under.")
endif()

add_subdirectory(src)

kpackage_install_package(spotify-widget org.kde.plasma.spotifywidget plasmoids plasma)
