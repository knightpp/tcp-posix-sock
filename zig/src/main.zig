const std = @import("std");
const net = std.net;
const posix = std.posix;
const lib = @import("lib");
const log = std.log.scoped(.client);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    const is_server = try std.process.hasEnvVar(alloc, "SERVER");

    const address = try net.Address.resolveIp("127.0.0.1", 5882);
    if (is_server) {
        var server = lib.Server.init(alloc, address, 4096);
        defer server.deinit();

        try server.run();
    } else {
        const n = 16;
        var handles: [n]std.Thread = undefined;
        for (0..n) |i| {
            const t = try std.Thread.spawn(.{}, flood, .{ alloc, address });
            handles[i] = t;
        }
        for (handles) |handle| {
            handle.join();
        }
    }
}

fn flood(alloc: std.mem.Allocator, address: std.net.Address) !void {
    const sock = try sockClient(address);
    defer posix.close(sock);

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    var i: usize = 0;
    const start = try std.time.Instant.now();
    defer {
        const end = std.time.Instant.now() catch unreachable;
        const elapsed = end.since(start);
        std.debug.print("processed={} took_ns={} rate_ms={}\n", .{ i, elapsed, @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(elapsed)) * 1_000_000.0 });
    }

    // std.Thread.spawn(.{.stack_size = 1*1024*1024}, , .{});
    while (true) {
        lib.protocol.writeMessage(.{ .handle = sock }, "hello world!") catch return;
        lib.protocol.readMessage(.{ .handle = sock }, &out) catch return;
        i += 1;
    }
}

fn sockClient(connect_to: std.net.Address) !posix.socket_t {
    const tpe: u32 = posix.SOCK.STREAM; // | posix.SOCK.NONBLOCK;
    const protocol = posix.IPPROTO.TCP;
    const sock = try posix.socket(connect_to.any.family, tpe, protocol);
    errdefer posix.close(sock);
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.connect(sock, &connect_to.any, connect_to.getOsSockLen());
    return sock;
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
