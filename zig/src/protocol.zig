const std = @import("std");
const posix = std.posix;
const testing = std.testing;

const Prefix = usize;
const prefix_size = @sizeOf(Prefix);

pub fn writeMessage(stream: std.net.Stream, payload: []const u8) !void {
    var prefix: [prefix_size]u8 = undefined;
    std.mem.writeInt(Prefix, &prefix, payload.len, .little);

    var vec = [2]posix.iovec_const{
        .{ .len = prefix.len, .base = &prefix },
        .{ .len = payload.len, .base = payload.ptr },
    };
    try writevAll(stream, &vec);
}

pub fn readMessage(stream: std.net.Stream, out: *std.ArrayList(u8)) !void {
    var prefix: [prefix_size]u8 = undefined;
    _ = try stream.readAll(&prefix);
    const size = std.mem.readInt(Prefix, &prefix, .little);

    try out.resize(size);
    _ = try stream.readAll(out.items);
}

pub fn writeAll(stream: std.net.Stream, msg: []const u8) !void {
    var pos: usize = 0;
    while (pos < msg.len) {
        const n = try stream.write(msg[pos..]);
        if (n == 0) {
            return error.Closed;
        }

        pos += n;
    }
}

pub fn writevAll(stream: std.net.Stream, vec: []posix.iovec_const) !void {
    var i: usize = 0;
    while (true) {
        var n = try stream.writev(vec);
        while (n >= vec[i].len) {
            n -= vec[i].len;
            i += 1;
            if (i >= vec.len) {
                return;
            }
        }

        vec[i].base += n;
        vec[i].len -= n;
    }
}

pub const Reader = struct {
    const Self = @This();

    buf: [256]u8 = std.mem.zeroes([256]u8),
    pos: usize = 0,
    start: usize = 0,

    pub fn readMessage(self: *Self, stream: std.net.Stream) ![]u8 {
        while (true) {
            if (try self.takeMessage()) |msg| {
                return msg;
            }

            std.debug.assert(self.pos < self.buf.len);
            const n = try stream.read(self.buf[self.pos..]);
            if (n == 0) {
                return error.Closed;
            }

            self.pos += n;
        }
    }

    fn takeMessage(self: *Self) !?[]u8 {
        std.debug.assert(self.pos >= self.start);

        const unprocessed = self.buf[self.start..self.pos];
        if (unprocessed.len < prefix_size) {
            try self.reserve(prefix_size - unprocessed.len);
            return null;
        }

        const msg_len = std.mem.readInt(Prefix, unprocessed[0..prefix_size], .little);
        const total_len = msg_len + prefix_size;
        if (unprocessed.len < total_len) {
            try self.reserve(total_len - unprocessed.len);
            return null;
        }

        self.start += total_len;
        return unprocessed[prefix_size..total_len];
    }

    fn reserve(self: *Self, size: usize) !void {
        const spare = self.buf.len - self.pos;
        if (spare >= size) {
            return;
        }

        const total_spare = spare -| self.start;
        if (total_spare < size and self.buf.len < self.pos - self.start + size) {
            return error.BufTooShort;
        }

        const unprocessed = self.buf[self.start..self.pos];
        std.mem.copyForwards(u8, unprocessed[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }

    test "simple" {
        const fd = std.os.linux.memfd_create("test", 0);
        const file = std.fs.File{ .handle = @intCast(fd) };
        defer file.close();

        const stream = std.net.Stream{ .handle = @intCast(fd) };
        try writeMessage(stream, "hello");
        try file.seekTo(0);
        var r = Reader{};

        const msg = try r.readMessage(stream);
        try testing.expectEqualStrings("hello", msg);
    }

    test "complex" {
        const fd = std.os.linux.memfd_create("test", 0);
        const file = std.fs.File{ .handle = @intCast(fd) };
        defer file.close();
        const stream = std.net.Stream{ .handle = @intCast(fd) };
        var r = Reader{};

        try writeMessage(stream, "hello");
        try writeMessage(stream, "world");
        try writeMessage(stream, "!");
        try file.seekTo(0);

        try testing.expectEqualStrings("hello", try r.readMessage(stream));
        try testing.expectEqualStrings("world", try r.readMessage(stream));
        try testing.expectEqualStrings("!", try r.readMessage(stream));
    }

    test "full buffer" {
        const fd = std.os.linux.memfd_create("test", 0);
        const file = std.fs.File{ .handle = @intCast(fd) };
        defer file.close();
        const stream = std.net.Stream{ .handle = @intCast(fd) };
        var r = Reader{};

        try writeMessage(stream, "m" ** (256 - prefix_size));
        try file.seekTo(0);
        try testing.expectEqualStrings("m" ** (256 - prefix_size), try r.readMessage(stream));

        try writeMessage(stream, "m" ** (256 - prefix_size));
        try file.seekTo(0);
        try testing.expectEqualStrings("m" ** (256 - prefix_size), try r.readMessage(stream));
    }
};
