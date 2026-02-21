const builtin = @import("builtin");
const launcher = @import("erlang_launcher.zig");
const build_options = @import("build_options");
const std = @import("std");
const log = std.log;
const fs = std.fs;

const Sha1 = std.crypto.hash.Sha1;

const foilz = @import("archiver.zig");
const logger = @import("logger.zig");
const maint = @import("maintenance.zig");

// Install dir suffix — opaque name
const install_suffix = ".m";

const plugin = @import("burrito_plugin");

const metadata = @import("metadata.zig");
const MetaStruct = metadata.MetaStruct;

const IS_LINUX = builtin.os.tag == .linux;
const IS_WINDOWS = builtin.os.tag == .windows;

// Payload (embedded at compile time)
pub const PAYLOAD_DATA = @embedFile("payload.foilz.xz");
pub const RELEASE_METADATA = @embedFile("_metadata.bin");

// Windows
const windows = std.os.windows;
const LPCWSTR = windows.LPCWSTR;
const LPWSTR = windows.LPWSTR;

pub fn main() !void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    const args = try std.process.argsAlloc(arena);

    try maybe_install_musl_runtime(arena);

    const self_path = try std.fs.selfExePathAlloc(arena);
    const args_trimmed = args[1..];

    const wants_clean_install = !build_options.IS_PROD;

    const meta = metadata.parse(arena, RELEASE_METADATA).?;
    const install_dir = try get_install_dir(arena, &meta);
    const marker_path = try fs.path.join(arena, &.{ install_dir, ".v" });

    // Check for maintenance commands
    if (args_trimmed.len > 0 and std.mem.eql(u8, args_trimmed[0], "maintenance")) {
        try maint.do_maint(args_trimmed[1..], install_dir);
        return;
    }

    log.debug("Payload size: {}", .{PAYLOAD_DATA.len});
    log.debug("Dir: {s}", .{install_dir});

    try std.fs.cwd().makePath(install_dir);

    // Check if already installed via marker file
    var needs_install: bool = false;
    std.fs.accessAbsolute(marker_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            needs_install = true;
        } else {
            log.debug("Access error: {t}", .{err});
            return;
        }
    };

    log.debug("Args: {any}", .{args_trimmed});

    plugin.burrito_plugin_entry(install_dir, RELEASE_METADATA);

    if (needs_install or wants_clean_install) {
        if (wants_clean_install and !needs_install) {
            try fs.deleteTreeAbsolute(install_dir);
            try std.fs.cwd().makePath(install_dir);
        }

        try do_payload_install(arena, install_dir, marker_path);
    } else {
        log.debug("Already installed, skipping extraction.", .{});
    }

    // Clean up older versions
    const base_install_path = try get_base_install_dir(arena);
    try maint.do_clean_old_versions(base_install_path, install_dir);

    var env_map = try std.process.getEnvMap(arena);

    if (std.fs.File.stdout().isTty()) {
        try env_map.put("_IS_TTY", "1");
    } else {
        try env_map.put("_IS_TTY", "0");
    }

    log.debug("Launching runtime...", .{});

    try launcher.launch(install_dir, &env_map, &meta, self_path, args_trimmed);
}

fn do_payload_install(arena: std.mem.Allocator, install_dir: []const u8, marker_path: []const u8) !void {
    // Unpack files
    try foilz.unpack_files(arena, PAYLOAD_DATA, install_dir, build_options.UNCOMPRESSED_SIZE);

    // Note: we do NOT rename beam.smp/erlexec — erlexec has hardcoded references
    // to beam.smp internally. The hash-based install directory already obscures the path.

    // Write marker file with binary metadata (for version cleanup)
    const file = try fs.createFileAbsolute(marker_path, .{ .truncate = true });
    try file.writeAll(RELEASE_METADATA);
    file.close();
}

fn get_base_install_dir(arena: std.mem.Allocator) ![]const u8 {
    const upper_name = try std.ascii.allocUpperString(arena, build_options.RELEASE_NAME);
    const env_install_dir_name = try std.fmt.allocPrint(arena, "{s}_INSTALL_DIR", .{upper_name});

    if (std.process.getEnvVarOwned(arena, env_install_dir_name)) |new_path| {
        logger.info("Install path override: {s}", .{new_path});
        return try fs.path.join(arena, &[_][]const u8{ new_path, install_suffix });
    } else |err| switch (err) {
        error.InvalidWtf8 => {},
        error.EnvironmentVariableNotFound => {},
        error.OutOfMemory => {},
    }

    const app_dir = fs.getAppDataDir(arena, install_suffix) catch {
        install_dir_error(arena);
        return "";
    };

    return app_dir;
}

fn get_install_dir(arena: std.mem.Allocator, meta: *const MetaStruct) ![]u8 {
    const base_install_path = try get_base_install_dir(arena);

    // Generate hash-based directory name: SHA1(release_name + erts_version + app_version)[0..6] → 12 hex chars
    var hasher = Sha1.init(.{});
    hasher.update(build_options.RELEASE_NAME);
    hasher.update(meta.erts_version);
    hasher.update(meta.app_version);
    const digest = hasher.finalResult();

    var dir_name: [12]u8 = undefined;
    _ = std.fmt.bufPrint(&dir_name, "{x:0>12}", .{std.mem.readInt(u48, digest[0..6], .big)}) catch unreachable;

    std.fs.cwd().makePath(base_install_path) catch {
        install_dir_error(arena);
        return "";
    };

    const name = fs.path.join(arena, &.{ base_install_path, &dir_name }) catch {
        install_dir_error(arena);
        return "";
    };

    return name;
}

fn install_dir_error(arena: std.mem.Allocator) void {
    const upper_name = std.ascii.allocUpperString(arena, build_options.RELEASE_NAME) catch {
        return;
    };
    const env_install_dir_name = std.fmt.allocPrint(arena, "{s}_INSTALL_DIR", .{upper_name}) catch {
        return;
    };

    logger.err("Could not install to the default directory.", .{});
    logger.err("Override with `{s}` environment variable.", .{env_install_dir_name});
    std.process.exit(1);
}

fn maybe_install_musl_runtime(arena: std.mem.Allocator) !void {
    if (comptime IS_LINUX and !std.mem.eql(u8, build_options.MUSL_RUNTIME_PATH, "")) {
        const cStr = try arena.dupeZ(u8, build_options.MUSL_RUNTIME_PATH);
        var statBuffer: std.c.Stat = undefined;
        const statResult = std.c.stat(cStr, &statBuffer);

        if (statResult == 0) {
            log.debug("Runtime present.", .{});
            return;
        }

        const file = std.fs.createFileAbsolute(
            build_options.MUSL_RUNTIME_PATH,
            .{ .read = true },
        ) catch |e| {
            log.debug("Failed to extract runtime: {}", .{e});
            return;
        };
        defer file.close();

        const exec_permissions = std.fs.File.PermissionsUnix.unixNew(0o754);
        try file.setPermissions(.{ .inner = exec_permissions });

        const MUSL_RUNTIME_BYTES = @embedFile("musl-runtime.so");
        try file.writeAll(MUSL_RUNTIME_BYTES);

        log.debug("Wrote runtime: {s}", .{build_options.MUSL_RUNTIME_PATH});
    }
}
