const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("justerm", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("X11-xcb");
    exe.linkSystemLibrary("util");
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("cairo");
    exe.linkSystemLibrary("pango");
    exe.linkSystemLibrary("pangocairo");
    exe.install();
}
