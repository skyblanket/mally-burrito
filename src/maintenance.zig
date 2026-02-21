const std = @import("std");

const logger = @import("logger.zig");
const metadata = @import("metadata.zig");
const install = @import("install.zig");
const wrapper = @import("wrapper.zig");

const MetaStruct = metadata.MetaStruct;

pub fn do_maint(args: [][:0]u8, install_dir: []const u8) !void {
    var stdout_buf: [64]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    if (args.len < 1) {
        logger.warn("No sub-command provided.", .{});
    } else {
        if (std.mem.eql(u8, args[0], "uninstall")) {
            try do_uninstall(install_dir);
        }

        if (std.mem.eql(u8, args[0], "directory")) {
            try print_install_dir(stdout, install_dir);
        }

        // "meta" command removed — no metadata to leak
    }
}

fn confirm() !bool {
    var stdin_buf: [8]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var stdin = &stdin_reader.interface;

    logger.query("Confirm [y/n]: ", .{});

    if (stdin.takeDelimiterExclusive('\n')) |user_input| {
        if (std.mem.eql(u8, user_input[0..1], "y") or std.mem.eql(u8, user_input[0..1], "Y")) {
            return true;
        }
    } else |err| {
        logger.err("Failed to confirm: {t}", .{err});
        return err;
    }

    return false;
}

fn do_uninstall(install_dir: []const u8) !void {
    logger.warn("This will uninstall the application runtime.", .{});
    if (try confirm() == false) {
        logger.warn("Aborted.", .{});
        return;
    }

    logger.info("Removing: {s}", .{install_dir});
    try std.fs.deleteTreeAbsolute(install_dir);
    logger.info("Done.", .{});
}

fn print_install_dir(out: *std.Io.Writer, install_dir: []const u8) !void {
    try out.print("{s}\n", .{install_dir});
    try out.flush();
}

pub fn do_clean_old_versions(install_prefix_path: []const u8, current_install_path: []const u8) !void {
    std.log.debug("Cleaning older versions...", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const prefix_dir = try std.fs.openDirAbsolute(install_prefix_path, .{ .access_sub_paths = true, .iterate = true });

    const current_install = try install.load_install_from_path(allocator, current_install_path);

    var itr = prefix_dir.iterate();
    while (try itr.next()) |dir| {
        if (dir.kind == .directory) {
            const possible_app_path = try std.fs.path.join(allocator, &[_][]const u8{ install_prefix_path, dir.name });
            const other_install = try install.load_install_from_path(allocator, possible_app_path);

            if (other_install == null) {
                continue;
            }

            if (current_install == null) {
                continue;
            }

            // Compare versions — delete older ones
            if (std.SemanticVersion.order(current_install.?.version, other_install.?.version) == .gt) {
                try std.fs.deleteTreeAbsolute(other_install.?.install_dir_path);
                logger.log_stderr("Removed older version (v{s})", .{other_install.?.metadata.app_version});
            }
        }
    }
}
