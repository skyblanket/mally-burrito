const std = @import("std");

const builtin = @import("builtin");
const fs = std.fs;
const log = std.log;
const metadata = @import("metadata.zig");
const win_ansi = @cImport(@cInclude("win_ansi_fix.h"));

const MetaStruct = metadata.MetaStruct;
const EnvMap = std.process.EnvMap;

const MAX_READ_SIZE = 256;

fn get_runtime_exe_name() []const u8 {
    if (builtin.os.tag == .windows) {
        return "mrt.exe";
    } else {
        return "mrt-exec";
    }
}

pub fn launch(install_dir: []const u8, env_map: *EnvMap, meta: *const MetaStruct, self_path: []const u8, args_trimmed: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    // Compute directories
    const release_cookie_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", "COOKIE" });
    const release_lib_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, "lib" });
    const install_vm_args_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", meta.app_version, "vm.args" });
    const config_sys_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", meta.app_version, "sys.config" });
    const config_sys_path_no_ext = try fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", meta.app_version, "sys" });
    const rel_vsn_dir = try fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", meta.app_version });
    const boot_path = try fs.path.join(allocator, &[_][]const u8{ rel_vsn_dir, "start" });

    var erts_pfx = [_]u8{ 0xc2, 0xd5, 0xd3, 0xd4, 0x8a }; // "erts-" ^ 0xa7
    for (&erts_pfx) |*b| b.* ^= 0xa7;
    const erts_version_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ &erts_pfx, meta.erts_version });
    const erts_bin_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, erts_version_name, "bin" });
    const erl_bin_path = try fs.path.join(allocator, &[_][]const u8{ erts_bin_path, get_runtime_exe_name() });

    // Read the cookie file
    const release_cookie_file = try fs.openFileAbsolute(release_cookie_path, .{ .mode = .read_write });
    var release_cookie_content = try release_cookie_file.readToEndAlloc(allocator, MAX_READ_SIZE);

    // Override cookie from env if set
    const maybe_cookie = std.process.getEnvVarOwned(allocator, "RELEASE_COOKIE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };

    if (maybe_cookie) |cookie| {
        release_cookie_content = cookie;
    }

    // Write a temporary args file containing the sensitive/identifying arguments.
    // This keeps them out of the process command line (visible via `ps`).
    const hidden_args_path = try fs.path.join(allocator, &[_][]const u8{ rel_vsn_dir, ".rt.args" });
    const hidden_args_file = try fs.createFileAbsolute(hidden_args_path, .{ .truncate = true });

    // Set restrictive permissions (owner read/write only)
    if (builtin.os.tag != .windows) {
        const perms = std.fs.File.PermissionsUnix.unixNew(0o600);
        try hidden_args_file.setPermissions(.{ .inner = perms });
    }

    // Write hidden args: cookie, boot module, port mapper disable
    // Boot module name XOR'd to prevent literal string in binary
    // 0x90,0x99,0x9c,0x8d,0x9c,0x87 = "elixir" XOR 0xf5
    var boot_mod: [6]u8 = .{ 0x90, 0x99, 0x9c, 0x8d, 0x9c, 0x87 };
    for (&boot_mod) |*b| b.* ^= 0xf5;
    var hidden_buf: [1024]u8 = undefined;
    var hidden_writer = hidden_args_file.writer(&hidden_buf);
    const hw = &hidden_writer.interface;
    try hw.print("-setcookie {s}\n", .{release_cookie_content});
    try hw.print("-{s} ansi_enabled true\n", .{&boot_mod});
    try hw.print("-s {s} start_cli\n", .{&boot_mod});
    try hw.writeAll("-start_epmd false\n");
    try hw.writeAll("-erl_epmd_port 0\n");
    try hw.flush();
    hidden_args_file.close();

    // Build the visible command line — no cookie, no -elixir, no -s elixir
    const erlang_cli = &[_][]const u8{
        erl_bin_path[0..],
        "-noshell",
        "-mode embedded",
        "-boot",
        boot_path,
        "-boot_var",
        "RELEASE_LIB",
        release_lib_path,
        "-args_file",
        install_vm_args_path,
        "-args_file",
        hidden_args_path,
        "-config",
        config_sys_path,
        "-extra",
    };

    if (builtin.os.tag == .windows) {
        win_ansi.enable_virtual_term();
        const final_args = try std.mem.concat(allocator, []const u8, &.{ erlang_cli, args_trimmed });

        try env_map.put("RELEASE_ROOT", install_dir);
        try env_map.put("RELEASE_SYS_CONFIG", config_sys_path_no_ext);
        try env_map.put("__MRT", "1");
        try env_map.put("__MRT_BP", self_path);

        var win_child_proc = std.process.Child.init(final_args, allocator);
        win_child_proc.env_map = env_map;
        win_child_proc.stdout_behavior = .Inherit;
        win_child_proc.stdin_behavior = .Inherit;

        log.debug("CLI: {any}", .{final_args});

        const win_term = try win_child_proc.spawnAndWait();
        switch (win_term) {
            .Exited => |code| {
                std.process.exit(code);
            },
            else => std.process.exit(1),
        }
    } else {
        const final_args = try std.mem.concat(allocator, []const u8, &.{ erlang_cli, args_trimmed });

        log.debug("CLI: {any}", .{final_args});

        var erl_env_map = EnvMap.init(allocator);
        defer erl_env_map.deinit();

        var env_map_it = env_map.iterator();
        while (env_map_it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            try erl_env_map.put(key, val);
        }

        try erl_env_map.put("ROOTDIR", install_dir[0..]);
        try erl_env_map.put("BINDIR", erts_bin_path[0..]);
        try erl_env_map.put("RELEASE_ROOT", install_dir);
        try erl_env_map.put("RELEASE_SYS_CONFIG", config_sys_path_no_ext);
        try erl_env_map.put("__MRT", "1");
        try erl_env_map.put("__MRT_BP", self_path);

        return std.process.execve(allocator, final_args, &erl_env_map);
    }
}
