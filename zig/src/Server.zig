const std = @import("std");
const posix = std.posix;
const PollClient = @import("clients.zig").PollClient;
const log = std.log.scoped(.server);
const milliTimestamp = std.time.milliTimestamp;

const Self = @This();
const TimeoutList = std.DoublyLinkedList(*PollClient);
const READ_TIMEOUT_MS = 1_000;

alloc: std.mem.Allocator,
address: std.net.Address,
poll_fds: std.ArrayList(posix.pollfd),

client_pool: std.heap.MemoryPool(PollClient),
clients: std.ArrayList(*PollClient),
timeout_pool: std.heap.MemoryPool(TimeoutList.Node),
timeouts: TimeoutList,

max_clients: usize,

pub fn init(alloc: std.mem.Allocator, address: std.net.Address, max_clients: usize) Self {
    std.debug.assert(max_clients > 0);

    return Self{
        .alloc = alloc,
        .client_pool = std.heap.MemoryPool(PollClient).init(alloc),
        .address = address,
        .poll_fds = std.ArrayList(posix.pollfd).init(alloc),
        .clients = std.ArrayList(*PollClient).init(alloc),
        .max_clients = max_clients,
        .timeouts = .{},
        .timeout_pool = std.heap.MemoryPool(TimeoutList.Node).init(alloc),
    };
}

pub fn deinit(self: *Self) void {
    for (self.poll_fds.items) |pfd| {
        posix.close(pfd.fd);
    }
    self.poll_fds.deinit();
    for (self.clients.items) |client| {
        self.client_pool.destroy(client);
    }
    self.clients.deinit();
    self.client_pool.deinit();
}

pub fn run(self: *Self) !void {
    const listener = try self.createListener();

    try self.clients.ensureTotalCapacityPrecise(self.max_clients);
    try self.poll_fds.ensureTotalCapacityPrecise(self.max_clients + 1);
    try self.poll_fds.append(.{ .fd = listener, .events = posix.POLL.IN, .revents = 0 });

    while (true) {
        const timeout = self.enforceTimeout();

        _ = try posix.poll(self.poll_fds.items, timeout);
        const accepted = try self.accept();

        var i: usize = 1;
        while (i < self.poll_fds.items.len - accepted) : (i += 1) {
            self.processPollFD(i) catch |err| {
                log.info("[{}] io error: {}", .{ self.clients.items[i - 1].address, err });
                self.removeClient(&i);
            };
        }
    }
}

fn enforceTimeout(self: *Self) i32 {
    const now = milliTimestamp();

    var node = self.timeouts.first;
    while (node) |n| {
        const client = n.data;
        const diff = client.read_timeout_ms - now;
        if (diff > 0) {
            return @intCast(diff);
        }
        posix.shutdown(client.stream.handle, .recv) catch {};
        node = n.next;
    } else {
        return -1;
    }
}

fn processPollFD(self: *Self, i: usize) !void {
    const pfd = &self.poll_fds.items[i];
    if (pfd.revents == 0) {
        return;
    }
    if (pfd.revents & posix.POLL.HUP == posix.POLL.HUP) {
        return error.PollHUP;
    }

    const client = self.clients.items[i - 1];
    if (hasPollBit(pfd.revents, posix.POLL.IN)) {
        const read_result = try client.readMessage();
        client.read_timeout_ms = milliTimestamp() + READ_TIMEOUT_MS;
        self.timeouts.remove(client.timeout_node);
        self.timeouts.append(client.timeout_node);

        const msg: []u8 = if (read_result) |msg| msg else return;

        log.debug("received: {s}", .{msg});
        if (try client.writeMessage(msg) == .complete) {
            return;
        }

        pfd.*.events = posix.POLL.OUT;
    } else if (hasPollBit(pfd.events, posix.POLL.OUT)) {
        const write_status = try client.write();
        if (write_status == .complete) {
            pfd.*.events = posix.POLL.IN;
            return;
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
        var address: std.net.Address = undefined;
        var address_len: posix.socklen_t = @sizeOf(std.net.Address);

        const conn = posix.accept(listener.fd, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
            error.WouldBlock => return accepted,
            else => return err,
        };
        errdefer posix.close(conn);

        const client: *PollClient = try self.client_pool.create();
        errdefer self.client_pool.destroy(client);

        client.* = try PollClient.init(self.alloc, conn, address);
        errdefer client.deinit(self.alloc);

        client.read_timeout_ms = milliTimestamp() + READ_TIMEOUT_MS;
        client.timeout_node = try self.timeout_pool.create();
        errdefer self.timeout_pool.destroy(client.timeout_node);
        client.timeout_node.data = client;

        self.timeouts.append(client.timeout_node);
        errdefer _ = self.timeouts.pop();

        try self.clients.append(client);
        errdefer _ = self.clients.pop();

        try self.poll_fds.append(.{ .fd = conn, .events = posix.POLL.IN, .revents = 0 });
        errdefer _ = self.poll_fds.pop();

        accepted += 1;
    } else {
        self.poll_fds.items[0].events = 0;
        return accepted;
    }
}

fn removeClient(self: *Self, index: *usize) void {
    std.debug.assert(index.* > 0);

    const pollfd = self.poll_fds.swapRemove(index.*);
    posix.close(pollfd.fd);

    const client = self.clients.swapRemove(index.* - 1);

    self.timeouts.remove(client.timeout_node);
    self.timeout_pool.destroy(client.timeout_node);
    self.client_pool.destroy(client);
    index.* -= 1;
    self.poll_fds.items[0].events = posix.POLL.IN;
}

fn hasPollBit(revents: i16, comptime bit: i16) bool {
    return revents & bit == bit;
}
