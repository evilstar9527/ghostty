const GhosttyXCFramework = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const GhosttyLib = @import("GhosttyLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");
const Target = @import("xcframework.zig").Target;

xcframework: *XCFrameworkStep,
target: Target,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !GhosttyXCFramework {
    // Native macOS build
    const macos_native = switch (target) {
        .native => try GhosttyLib.initStatic(b, &try deps.retarget(
            b,
            Config.genericMacOSTarget(b, null),
        )),
        .universal => null,
    };

    const universal = switch (target) {
        .native => null,
        .universal => .{
            // Universal macOS build
            .macos = try GhosttyLib.initMacOSUniversal(b, deps),

            // iOS
            .ios = try GhosttyLib.initStatic(b, &try deps.retarget(
                b,
                b.resolveTargetQuery(.{
                    .cpu_arch = .aarch64,
                    .os_tag = .ios,
                    .os_version_min = Config.osVersionMin(.ios),
                    .abi = null,
                }),
            )),

            // iOS Simulator
            .ios_sim = try GhosttyLib.initStatic(b, &try deps.retarget(
                b,
                b.resolveTargetQuery(.{
                    .cpu_arch = .aarch64,
                    .os_tag = .ios,
                    .os_version_min = Config.osVersionMin(.ios),
                    .abi = .simulator,

                    // We force the Apple CPU model because the simulator
                    // doesn't support the generic CPU model as of Zig 0.14 due
                    // to missing "altnzcv" instructions, which is false. This
                    // surely can't be right but we can fix this if/when we get
                    // back to running simulator builds.
                    .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_a17 },
                }),
            )),
        },
    };

    // Generate a headers directory with only ghostty.h and the module
    // map. We can't use include/ directly because it also contains the
    // libghostty-vt headers under include/ghostty/, which would trigger
    // "umbrella header does not include header" warnings from Clang's
    // module system.
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path("include/ghostty.h"), "ghostty.h");
    _ = wf.addCopyFile(b.path("include/module.modulemap"), "module.modulemap");
    const headers = wf.getDirectory();

    // The xcframework wraps our ghostty library so that we can link
    // it to the final app built with Swift.
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "GhosttyKit",
        .out_path = "macos/GhosttyKit.xcframework",
        .libraries = switch (target) {
            .universal => &.{
                .{
                    .library = universal.?.macos.output,
                    .headers = headers,
                    .dsym = universal.?.macos.dsym,
                },
                .{
                    .library = universal.?.ios.output,
                    .headers = headers,
                    .dsym = universal.?.ios.dsym,
                },
                .{
                    .library = universal.?.ios_sim.output,
                    .headers = headers,
                    .dsym = universal.?.ios_sim.dsym,
                },
            },

            .native => &.{.{
                .library = macos_native.?.output,
                .headers = headers,
                .dsym = macos_native.?.dsym,
            }},
        },
    });

    return .{
        .xcframework = xcframework,
        .target = target,
    };
}

pub fn install(self: *const GhosttyXCFramework) void {
    const b = self.xcframework.step.owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyXCFramework,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(self.xcframework.step);
}
