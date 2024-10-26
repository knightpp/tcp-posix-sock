const std = @import("std");
const posix = std.posix;
const Client = @import("Client.zig");
const log = std.log.scoped(.server);

const Self = @This();

address: std.net.Address,
poll_fds: std.ArrayList(posix.pollfd),

pub fn init(alloc: std.mem.Allocator, address: std.net.Address) Self {
    return Self{
        .address = address,
        .poll_fds = std.ArrayList(posix.pollfd).init(alloc),
    };
}

pub fn deinit(self: *Self) void {
    for (self.poll_fds.items) |pfd| {
        posix.close(pfd.fd);
    }
    self.poll_fds.deinit();
}

pub fn run(self: *Self) !void {
    const listener = try self.createListener();

    try self.poll_fds.append(.{ .fd = listener, .events = posix.POLL.IN, .revents = 0 });

    var read_buf: [4096]u8 = undefined;
    while (true) {
        _ = try posix.poll(self.poll_fds.items, -1);

        const listener_pfd = self.poll_fds.items[0];
        if (listener_pfd.revents != 0) {
            while (true) {
                const conn = posix.accept(listener_pfd.fd, null, null, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return err,
                };
                try self.poll_fds.append(.{ .fd = conn, .events = posix.POLL.IN, .revents = 0 });
            }
        }

        var i: usize = 1;
        while (i < self.poll_fds.items.len) : (i += 1) {
            const pfd = self.poll_fds.items[i];
            if (pfd.revents == 0) {
                continue;
            }
            if (pfd.revents & posix.POLL.HUP == posix.POLL.HUP) {
                log.info("closing client reason=HUP", .{});
                _ = self.poll_fds.swapRemove(i);
                i -= 1;
                continue;
            }

            const read = posix.read(pfd.fd, &read_buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => blk: {
                    log.err("read error: {}", .{err});
                    break :blk 0;
                },
            };
            if (read == 0) {
                log.info("closing client reason=0read", .{});
                const removed = self.poll_fds.swapRemove(i);
                posix.close(removed.fd);
                i -= 1;
                continue;
            }

            log.info("received: {s}", .{read_buf[0..read]});
        }
    }
}

fn createListener(self: *const Self) !posix.fd_t {
    const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(self.address.any.family, tpe, protocol);
    errdefer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &self.address.any, self.address.getOsSockLen());
    try posix.listen(listener, 128);

    return listener;
}
