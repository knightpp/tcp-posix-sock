const std = @import("std");
const net = std.net;
const posix = std.posix;
const lib = @import("lib");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    const address = try net.Address.resolveIp("127.0.0.1", 5882);

    var server = lib.Server.init(alloc, address, 4096);
    defer server.deinit();

    try server.run();
}

fn threadPool(alloc: std.mem.Allocator) !void {
    const address = try net.Address.resolveIp("127.0.0.1", 5882);

    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(address.any.family, tpe, protocol);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 128);

    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = alloc, .n_jobs = 64 });

    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);

        const fd = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("error accept: {}\n", .{err});
            continue;
        };

        const client = lib.Client{ .address = client_address, .socket = fd };
        try pool.spawn(lib.Client.handle, .{client});
    }
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
