const std = @import("std");
const metadata = @import("metadata.zig");
const MetaStruct = metadata.MetaStruct;

const MAX_READ_SIZE = 1000000000;

pub const Install = struct {
    marker_file_path: []const u8 = undefined,
    base_install_dir_path: []const u8 = undefined,
    install_dir_path: []const u8 = undefined,
    metadata: MetaStruct = undefined,
    version: std.SemanticVersion = undefined,
};

pub fn load_install_from_path(allocator: std.mem.Allocator, full_install_path: []const u8) !?Install {
    // Read binary metadata from .v marker file
    const marker_path = try std.fs.path.join(allocator, &[_][]const u8{ full_install_path, ".v" });
    const marker_file = std.fs.openFileAbsolute(marker_path, .{}) catch {
        return null;
    };

    defer marker_file.close();

    const content = try marker_file.readToEndAlloc(allocator, MAX_READ_SIZE);
    const metadata_struct = metadata.parse(allocator, content);

    if (metadata_struct == null) {
        return null;
    }

    const parsed_version = std.SemanticVersion.parse(metadata_struct.?.app_version) catch {
        return null;
    };

    return Install{
        .marker_file_path = marker_path,
        .base_install_dir_path = full_install_path,
        .install_dir_path = full_install_path,
        .metadata = metadata_struct.?,
        .version = parsed_version,
    };
}
