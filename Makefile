TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = PodcastThis

# Support rootless jailbreaks by default (Dopamine, etc.)
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = PodcastThis

PodcastThis_FILES = ios-app/PodcastThisApp.swift \
                    ios-app/PodcastModel.swift \
                    ios-app/DataManager.swift \
                    ios-app/PodcastPlayer.swift \
                    ios-app/LibraryView.swift \
                    ios-app/SubscriptionsView.swift \
                    ios-app/PlayerView.swift \
                    ios-app/SkipEditorView.swift \
                    ios-app/SpeakerSkipView.swift \
                    ios-app/AddView.swift \
                    ios-app/SettingsView.swift \
                    ios-app/ChannelBrowserView.swift

PodcastThis_FRAMEWORKS = UIKit AVFoundation MediaPlayer Combine
PodcastThis_CODESIGN_FLAGS = -Sentitlements.plist
PodcastThis_RESOURCE_FILES = ios-app/Info.plist ios-app/Icon.png ios-app/Icon@2x.png ios-app/Icon@3x.png

include $(THEOS_MAKE_PATH)/application.mk

APPEX_NAME = PodcastThisShare PodcastThisAction

PodcastThisShare_FILES = ios-share-extension/ShareViewController.swift
PodcastThisShare_FRAMEWORKS = UIKit Social MobileCoreServices UniformTypeIdentifiers
PodcastThisShare_CODESIGN_FLAGS = -Sentitlements.plist
PodcastThisShare_INSTALL_PATH = /Applications/PodcastThis.app/PlugIns
PodcastThisShare_RESOURCE_FILES = ios-share-extension/Info.plist ios-share-extension/Icon.png ios-share-extension/Icon@2x.png ios-share-extension/Icon@3x.png

PodcastThisAction_FILES = ios-share-extension/ShareViewController.swift
PodcastThisAction_FRAMEWORKS = UIKit Social MobileCoreServices UniformTypeIdentifiers
PodcastThisAction_CODESIGN_FLAGS = -Sentitlements.plist
PodcastThisAction_INSTALL_PATH = /Applications/PodcastThis.app/PlugIns
PodcastThisAction_RESOURCE_FILES = ios-action-extension/Info.plist ios-action-extension/Icon.png ios-action-extension/Icon@2x.png ios-action-extension/Icon@3x.png ios-action-extension/Assets.car

include $(THEOS_MAKE_PATH)/appex.mk


