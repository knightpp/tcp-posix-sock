const std = @import("std");
const posix = std.posix;
const Client = @import("clients.zig").PollClient;
const log = std.log.scoped(.server);

const Self = @This();

address: std.net.Address,
poll_fds: std.ArrayList(posix.pollfd),
clients: std.ArrayList(Client),
max_clients: usize,

pub fn init(alloc: std.mem.Allocator, address: std.net.Address, max_clients: usize) Self {
    std.debug.assert(max_clients > 0);

    return Self{
        .address = address,
        .poll_fds = std.ArrayList(posix.pollfd).init(alloc),
        .clients = std.ArrayList(Client).init(alloc),
        .max_clients = max_clients,
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

    try self.clients.ensureTotalCapacityPrecise(self.max_clients);
    try self.poll_fds.ensureTotalCapacityPrecise(self.max_clients + 1);

    try self.poll_fds.append(.{ .fd = listener, .events = posix.POLL.IN, .revents = 0 });

    var read_buf: [4096]u8 = undefined;
    while (true) {
        _ = try posix.poll(self.poll_fds.items, -1);
        const accepted = try self.accept();

        var i: usize = 1;
        while (i < self.poll_fds.items.len - accepted) : (i += 1) {
            const pfd = self.poll_fds.items[i];
            if (pfd.revents == 0) {
                continue;
            }
            if (pfd.revents & posix.POLL.HUP == posix.POLL.HUP) {
                log.info("closing client reason=HUP", .{});
                self.removeClient(&i);
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
                self.removeClient(&i);
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

fn accept(self: *Self) !usize {
    const listener = self.poll_fds.items[0];
    if (listener.revents == 0) {
        return 0;
    }

    const available = self.max_clients - self.poll_fds.items.len - 1;
    var accepted: usize = 0;
    for (0..available) |_| {
        const conn = posix.accept(listener.fd, null, null, posix.SOCK.NONBLOCK) catch |err| switch (err) {
            error.WouldBlock => return accepted,
            else => return err,
        };

        try self.poll_fds.append(.{ .fd = conn, .events = posix.POLL.IN, .revents = 0 });
        accepted += 1;
    } else {
        self.poll_fds.items[0].events = 0;
        return accepted;
    }
}

fn removeClient(self: *Self, index: *usize) void {
    const removed = self.poll_fds.swapRemove(index.*);
    posix.close(removed.fd);
    index.* -= 1;
    self.poll_fds.items[0].events = posix.POLL.IN;
}
