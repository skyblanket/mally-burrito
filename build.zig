const std = @import("std");
const foilz = @import("src/archiver.zig");
const builtin = @import("builtin");

const log = std.log;

pub fn build(b: *std.Build) !void {
    log.info("Building release...", .{});

    try run_archiver(b);
    try build_wrapper(b);

    log.info("Done.", .{});
}

pub fn run_archiver(b: *std.Build) !void {
    log.info("Compressing payload...", .{});

    const release_path = try std.process.getEnvVarOwned(b.allocator, "__MRT_RELEASE_PATH");
    try foilz.pack_directory(b.allocator, release_path, "./payload.foilz");

    if (builtin.os.tag == .windows) {
        _ = b.run(&[_][]const u8{
            "cmd",
            "/C",
            "xz -9ez --check=crc32 --stdout --keep payload.foilz > src/payload.foilz.xz",
        });
    } else {
        _ = b.run(&[_][]const u8{
            "/bin/sh",
            "-c",
            "xz -9ez --check=crc32 --stdout --keep payload.foilz > src/payload.foilz.xz",
        });
    }
}

pub fn build_wrapper(b: *std.Build) !void {
    log.info("Embedding payload...", .{});

    const release_name = try std.process.getEnvVarOwned(b.allocator, "__MRT_RELEASE_NAME");
    const plugin_path = std.process.getEnvVarOwned(b.allocator, "__MRT_PLUGIN_PATH") catch null;
    const is_prod = std.process.getEnvVarOwned(b.allocator, "__MRT_IS_PROD") catch "1";
    const musl_runtime_path = std.process.getEnvVarOwned(b.allocator, "__MRT_MUSL_RUNTIME_PATH") catch "";
    var opt_level = std.builtin.OptimizeMode.Debug;

    if (std.mem.eql(u8, is_prod, "1")) {
        opt_level = std.builtin.OptimizeMode.ReleaseSmall;
    }

    var file = try std.fs.cwd().openFile("payload.foilz", .{});
    defer file.close();
    const uncompressed_size = try file.getEndPos();
    const target = b.standardTargetOptions(.{});

    const wrapper_exe = b.addExecutable(.{
        .name = release_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wrapper.zig"),
            .target = target,
            .optimize = opt_level,
        }),
    });

    const exe_options = b.addOptions();
    wrapper_exe.root_module.addOptions("build_options", exe_options);

    exe_options.addOption([]const u8, "RELEASE_NAME", release_name);
    exe_options.addOption(u64, "UNCOMPRESSED_SIZE", uncompressed_size);

    exe_options.addOption(bool, "IS_PROD", std.mem.eql(u8, is_prod, "1"));
    exe_options.addOption([]const u8, "MUSL_RUNTIME_PATH", musl_runtime_path);

    if (target.result.os.tag == .windows) {
        wrapper_exe.addIncludePath(b.path("src/"));
    }

    wrapper_exe.linkSystemLibrary("c");

    if (plugin_path) |plugin| {
        log.info("Plugin: {s}", .{plugin});
        const plug_mod = b.addModule("burrito_plugin", .{
            .root_source_file = .{ .cwd_relative = plugin },
        });
        wrapper_exe.root_module.addImport("burrito_plugin", plug_mod);
    } else {
        const plug_mod = b.addModule("burrito_plugin", .{
            .root_source_file = b.path("_dummy_plugin.zig"),
        });
        wrapper_exe.root_module.addImport("burrito_plugin", plug_mod);
    }

    wrapper_exe.addIncludePath(b.path("src/xz"));
    wrapper_exe.addCSourceFile(.{ .file = b.path("src/xz/xz_crc32.c") });
    wrapper_exe.addCSourceFile(.{ .file = b.path("src/xz/xz_dec_lzma2.c") });
    wrapper_exe.addCSourceFile(.{ .file = b.path("src/xz/xz_dec_stream.c") });

    b.installArtifact(wrapper_exe);
}
