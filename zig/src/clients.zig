const std = @import("std");
const posix = std.posix;
const proto = @import("protocol.zig");

const SyncClient = struct {
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
};

pub const PollClient = struct {
    const Self = @This();
    const log = std.log.scoped(.poll_client);

    address: std.net.Address,
    stream: std.net.Stream,
    reader: proto.Reader,
    to_write: []u8,
    write_buf: []u8,
    read_timeout_ms: i64,
    timeout_node: *std.DoublyLinkedList(*Self).Node,

    pub fn init(alloc: std.mem.Allocator, socket: posix.socket_t, address: std.net.Address) !Self {
        var reader = try proto.Reader.init(alloc, 4096);
        errdefer reader.deinit(alloc);

        const write_buf = try alloc.alloc(u8, 4096);
        errdefer alloc.free(write_buf);

        return .{
            .address = address,
            .stream = std.net.Stream{ .handle = socket },
            .reader = reader,
            .write_buf = write_buf,
            .to_write = &.{},
            .read_timeout_ms = 0, // server sets this
            .timeout_node = undefined, // HACK: is set after init
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.reader.deinit(alloc);
        alloc.free(self.write_buf);
        self.write_buf = &.{};
        self.to_write = &.{};
    }

    pub fn readMessage(self: *PollClient) !?[]u8 {
        return self.reader.readMessage(self.stream) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }

    pub fn writeMessage(self: *PollClient, msg: []u8) !WriteStatus {
        std.debug.assert(msg.len != 0);
        if (self.to_write.len > 0) {
            return error.PendingMessage;
        }
        if (msg.len + proto.prefix_size > self.write_buf.len) {
            return error.MessageTooLarge;
        }

        const size = proto.prefix_size + msg.len;
        @memcpy(self.write_buf[0..proto.prefix_size], &proto.prefixBytes(msg.len));
        @memcpy(self.write_buf[proto.prefix_size..size], msg);
        self.to_write = self.write_buf[0..size];
        return try self.write();
    }

    pub const WriteStatus = enum {
        incomplete,
        complete,
    };

    pub fn write(self: *PollClient) !WriteStatus {
        var buf = self.to_write;
        defer self.to_write = buf;

        while (buf.len > 0) {
            const n = posix.write(self.stream.handle, buf) catch |err| switch (err) {
                error.WouldBlock => return .incomplete,
                else => return err,
            };
            if (n == 0) {
                return error.Closed;
            }

            buf = buf[n..];
        } else {
            return .complete;
        }
    }
};
