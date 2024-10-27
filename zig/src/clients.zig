const std = @import("std");
const posix = std.posix;
const proto = @import("protocol.zig");

const Self = @This();

address: std.net.Address,
socket: posix.socket_t,

pub fn handle(self: Self) void {
    self._handle() catch |err| switch (err) {
        error.Closed => {},
        else => std.debug.print("[{}] client handle error: {}\n", .{ self.address, err }),
    };
}

fn _handle(self: Self) !void {
    defer posix.close(self.socket);

    std.debug.print("{} connected\n", .{self.address});

    const timeout = posix.timeval{ .tv_sec = 60, .tv_usec = 500 };
    inline for (.{ posix.SO.SNDTIMEO, posix.SO.RCVTIMEO }) |opt| {
        try posix.setsockopt(self.socket, posix.SOL.SOCKET, opt, &std.mem.toBytes(timeout));
    }

    const socket = std.net.Stream{ .handle = self.socket };
    while (true) {
        var buf: [128]u8 = undefined;
        const read = try socket.read(&buf);
        if (read == 0) {
            return error.Closed;
        }

        try proto.writeAll(socket, buf[0..read]);
    }
}
