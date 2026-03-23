const std = @import("std");
const posix = std.posix;

pub const BUFSIZE: usize = 4096;
pub const EOS = "\x1b[999H";
pub const VERSION = "0.1.0";

pub const MessageType = enum(u8) {
    push = 0,
    attach = 1,
    detach = 2,
    winch = 3,
    redraw = 4,
};

pub const RedrawMethod = enum(u8) {
    unspec = 0,
    none = 1,
    ctrl_l = 2,
    winch = 3,
};

pub const Packet = extern struct {
    type: MessageType,
    len: u8,
    u: extern union {
        buf: [@sizeOf(posix.winsize)]u8,
        ws: posix.winsize,
    },

    pub fn zeroed() Packet {
        return std.mem.zeroes(Packet);
    }

    pub fn asBytes(self: *const Packet) []const u8 {
        return std.mem.asBytes(self);
    }
};

/// Write buf to fd handling partial writes. Exit process on failure.
pub fn writeBufOrFail(fd: posix.fd_t, buf: []const u8) void {
    var remaining = buf;
    while (remaining.len > 0) {
        const rc = std.c.write(fd, remaining.ptr, remaining.len);
        if (rc < 0) {
            const fail_msg = EOS ++ "\r\n[write failed]\r\n";
            _ = std.c.write(posix.STDOUT_FILENO, fail_msg.ptr, fail_msg.len);
            std.c._exit(1);
        }
        const written: usize = @intCast(rc);
        remaining = remaining[written..];
    }
}

/// Write a full packet atomically. Exit process on failure.
pub fn writePacketOrFail(fd: posix.fd_t, pkt: *const Packet) void {
    const bytes = pkt.asBytes();
    const rc = std.c.write(fd, bytes.ptr, bytes.len);
    if (rc < 0 or @as(usize, @intCast(rc)) != bytes.len) {
        const fail_msg = EOS ++ "\r\n[write failed]\r\n";
        _ = std.c.write(posix.STDOUT_FILENO, fail_msg.ptr, fail_msg.len);
        std.c._exit(1);
    }
}

// APC-based pty size notification (master → client, inline with data stream)
// Format: ESC _ ZTACH; <cols> ; <rows> ESC backslash
pub const APC_PREFIX = "\x1b_ZTACH;";
pub const APC_SUFFIX = "\x1b\\";

/// Format and write a pty size notification to a client fd.
/// Uses a stack buffer — no allocations.
pub fn writeSizeNotification(fd: posix.fd_t, cols: u16, rows: u16) void {
    var buf: [48]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{d};{d}{s}", .{
        APC_PREFIX, cols, rows, APC_SUFFIX,
    }) catch return;
    _ = std.c.write(fd, msg.ptr, msg.len);
}
