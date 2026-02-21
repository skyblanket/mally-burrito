const std = @import("std");

/// Compact binary metadata format — no JSON, no human-readable field names.
/// Layout: [u8 app_version_len][app_version bytes][u8 erts_version_len][erts_version bytes]
pub const MetaStruct = struct {
    app_version: []const u8 = undefined,
    erts_version: []const u8 = undefined,
};

pub fn parse(_: std.mem.Allocator, data: []const u8) ?MetaStruct {
    if (data.len < 2) return null;

    var cursor: usize = 0;

    // Read app_version
    const av_len: usize = data[cursor];
    cursor += 1;
    if (cursor + av_len > data.len) return null;
    const app_version = data[cursor .. cursor + av_len];
    cursor += av_len;

    // Read erts_version
    if (cursor >= data.len) return null;
    const ev_len: usize = data[cursor];
    cursor += 1;
    if (cursor + ev_len > data.len) return null;
    const erts_version = data[cursor .. cursor + ev_len];

    return MetaStruct{
        .app_version = app_version,
        .erts_version = erts_version,
    };
}
