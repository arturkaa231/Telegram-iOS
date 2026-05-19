load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "MediaBrowserUI",
    module_name = "MediaBrowserUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/Postbox",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/AccountContext",
        "//submodules/TelegramPresentationData",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUniversalVideoContent",
        "//submodules/GalleryUI",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/AvatarNode",
        "//submodules/Utils/RangeSet:RangeSet",
        "//submodules/ShareController",
    ],
    visibility = [
        "//visibility:public",
    ],
)
