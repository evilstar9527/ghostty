#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, Ghostty-iOS, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" {
        [-skip-testing GhosttyUITests]
    } else {
        []
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($build_dir)"
        ...$skip_testing
        $action)

    if $env.LAST_EXIT_CODE != 0 {
        exit $env.LAST_EXIT_CODE
    }

    if $action == "build" and $scheme == "Ghostty" {
        resign-ghostty-app $build_dir $configuration
    }
}

def resign-ghostty-app [
    build_dir: path
    configuration: string
] {
    let app_dir = ($build_dir | path join $configuration)
    let ghostty_plus_app = ($app_dir | path join "Ghostty++.app")
    let ghostty_app = ($app_dir | path join "Ghostty.app")
    let app = if ($ghostty_plus_app | path exists) {
        $ghostty_plus_app
    } else {
        $ghostty_app
    }

    if not ($app | path exists) {
        return
    }

    let entitlements_file = match $configuration {
        "Debug" => "GhosttyDebug.entitlements",
        "Release" => "Ghostty.entitlements",
        "ReleaseLocal" => "GhosttyReleaseLocal.entitlements",
        _ => null,
    }

    if $entitlements_file == null {
        return
    }

    let nested_code = [
        ($app | path join "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"),
        ($app | path join "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"),
        ($app | path join "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"),
        ($app | path join "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"),
        ($app | path join "Contents/Frameworks/Sparkle.framework"),
        ($app | path join "Contents/PlugIns/DockTilePlugin.plugin"),
    ]

    for code in $nested_code {
        if ($code | path exists) {
            ^codesign --force --sign - --options runtime $code

            if $env.LAST_EXIT_CODE != 0 {
                exit $env.LAST_EXIT_CODE
            }
        }
    }

    let entitlements = ($env.FILE_PWD | path join $entitlements_file)

    ^codesign --force --sign - --options runtime --entitlements $entitlements $app

    if $env.LAST_EXIT_CODE != 0 {
        exit $env.LAST_EXIT_CODE
    }

    ^codesign --verify --deep --strict --verbose=2 $app

    if $env.LAST_EXIT_CODE != 0 {
        exit $env.LAST_EXIT_CODE
    }

    let result = (^codesign -d --entitlements - $app | complete)
    let output = $"($result.stdout)($result.stderr)"

    if not ($output | str contains "com.apple.security.cs.disable-library-validation") {
        error make {
            msg: $"codesign did not apply com.apple.security.cs.disable-library-validation to ($app)"
        }
    }
}
