const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const proto = @import("protocol.zig");

const Packet = proto.Packet;
const RedrawMethod = proto.RedrawMethod;

const TIOCGWINSZ: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(c_uint, 0x40087468)),
    .linux => 0x5413,
    else => @compileError("unsupported OS"),
};

var cur_term: posix.termios = undefined;
var win_changed: bool = false;
var orig_term_ptr: *const posix.termios = undefined;

// Viewport state
var pty_cols: u16 = 0;
var pty_rows: u16 = 0;
var term_cols: u16 = 0;
var term_rows: u16 = 0;
var viewport_active: bool = false;
var too_small: bool = false;

fn restoreTerm() callconv(.c) void {
    // Disable focus reporting
    const focus_off = "\x1b[?1004l";
    _ = std.c.write(posix.STDOUT_FILENO, focus_off.ptr, focus_off.len);
    // Reset VT100 margins and origin mode before restoring terminal
    if (viewport_active) {
        const reset = "\x1b[?6l" ++ // disable origin mode
            "\x1b[?69l" ++ // disable DECLRMM
            "\x1b[r" ++ // reset DECSTBM (full screen)
            "\x1b[?25h"; // show cursor
        _ = std.c.write(posix.STDOUT_FILENO, reset.ptr, reset.len);
    }
    posix.tcsetattr(posix.STDIN_FILENO, .DRAIN, orig_term_ptr.*) catch {};
    const msg = "\x1b[?25h";
    _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
}

fn die(sig: posix.SIG) callconv(.c) void {
    restoreTerm();
    if (sig == posix.SIG.HUP or sig == posix.SIG.INT) {
        const msg = proto.EOS ++ "\r\n[detached]\r\n";
        _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
    } else {
        const msg = proto.EOS ++ "\r\n[got signal - dying]\r\n";
        _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
    }
    std.c._exit(1);
}

fn winChange(_: posix.SIG) callconv(.c) void {
    win_changed = true;
}

fn connectSocket(name: [:0]const u8) !posix.fd_t {
    if (name.len > 104 - 1) return error.NameTooLong;

    const s = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (s < 0) return error.SocketFailed;
    errdefer _ = std.c.close(s);

    var addr: std.c.sockaddr.un = std.mem.zeroes(std.c.sockaddr.un);
    addr.family = std.c.AF.UNIX;
    const name_bytes: []const u8 = name;
    @memcpy(addr.path[0..name_bytes.len], name_bytes);

    const addr_len: std.c.socklen_t = @intCast(@sizeOf(std.c.sa_family_t) + name_bytes.len + 1);
    const rc = std.c.connect(s, @ptrCast(&addr), addr_len);
    if (rc < 0) return error.ConnectFailed;
    return s;
}

// Viewport / margin management

fn getTermSize() void {
    var ws: posix.winsize = std.mem.zeroes(posix.winsize);
    _ = std.c.ioctl(posix.STDIN_FILENO, TIOCGWINSZ, @intFromPtr(&ws));
    term_cols = ws.col;
    term_rows = ws.row;
}

fn showTooSmall() void {
    proto.writeBufOrFail(posix.STDOUT_FILENO, "\x1b[?6l\x1b[?69l\x1b[r\x1b[H\x1b[2J\x1b[2m");

    const msg1 = "Session active on larger display";
    var msg2_buf: [64]u8 = undefined;
    const msg2 = std.fmt.bufPrint(&msg2_buf, "{d}x{d} needed, {d}x{d} available", .{
        pty_cols, pty_rows, term_cols, term_rows,
    }) catch return;

    const row1: u16 = if (term_rows > 3) term_rows / 2 else 1;
    const col1: u16 = if (term_cols > msg1.len) (term_cols - @as(u16, @intCast(msg1.len))) / 2 + 1 else 1;
    const col2: u16 = if (term_cols > msg2.len) (term_cols - @as(u16, @intCast(msg2.len))) / 2 + 1 else 1;

    var esc_buf: [32]u8 = undefined;
    const mv1 = std.fmt.bufPrint(&esc_buf, "\x1b[{d};{d}H", .{ row1, col1 }) catch return;
    proto.writeBufOrFail(posix.STDOUT_FILENO, mv1);
    proto.writeBufOrFail(posix.STDOUT_FILENO, msg1);

    const mv2 = std.fmt.bufPrint(&esc_buf, "\x1b[{d};{d}H", .{ row1 + 1, col2 }) catch return;
    proto.writeBufOrFail(posix.STDOUT_FILENO, mv2);
    proto.writeBufOrFail(posix.STDOUT_FILENO, msg2);

    proto.writeBufOrFail(posix.STDOUT_FILENO, "\x1b[22m");
}

fn setupViewport() void {
    if (pty_cols == 0 or pty_rows == 0) return;
    getTermSize();
    if (term_cols == 0 or term_rows == 0) return;

    // If our terminal is smaller than the pty, show "too small" overlay
    if (term_cols < pty_cols or term_rows < pty_rows) {
        if (viewport_active) teardownViewport();
        too_small = true;
        showTooSmall();
        return;
    }

    // No longer too small — clear the stale overlay
    if (too_small) {
        too_small = false;
        proto.writeBufOrFail(posix.STDOUT_FILENO, "\x1b[H\x1b[2J");
    }

    // If our terminal matches the pty size exactly, no viewport needed
    if (term_cols <= pty_cols and term_rows <= pty_rows) {
        if (viewport_active) teardownViewport();
        return;
    }

    viewport_active = true;

    // Calculate centering offsets (1-based for VT100)
    const pad_left: u16 = if (term_cols > pty_cols) (term_cols - pty_cols) / 2 else 0;
    const pad_top: u16 = if (term_rows > pty_rows) (term_rows - pty_rows) / 2 else 0;

    // Content area (1-based VT100 coordinates)
    const left: u16 = pad_left + 1;
    const top: u16 = pad_top + 1;
    const right: u16 = left + pty_cols - 1;
    const bottom: u16 = top + pty_rows - 1;

    // 1. Disable origin mode and margins first, clear screen
    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    // Reset everything
    const reset = "\x1b[?6l" ++ // origin mode off
        "\x1b[?69l" ++ // DECLRMM off
        "\x1b[r" ++ // reset DECSTBM
        "\x1b[H\x1b[2J"; // cursor home + clear screen
    @memcpy(buf[pos .. pos + reset.len], reset);
    pos += reset.len;
    proto.writeBufOrFail(posix.STDOUT_FILENO, buf[0..pos]);
    pos = 0;

    // 2. Draw border (box-drawing characters, centered)
    drawBorder(pad_left, pad_top, pty_cols, pty_rows);

    // 3. Set VT100 margins
    // DECSTBM: set top/bottom margins
    const stbm = std.fmt.bufPrint(&buf, "\x1b[{d};{d}r", .{ top, bottom }) catch return;
    proto.writeBufOrFail(posix.STDOUT_FILENO, stbm);

    // DECLRMM: enable left/right margin mode
    proto.writeBufOrFail(posix.STDOUT_FILENO, "\x1b[?69h");

    // DECSLRM: set left/right margins
    const slrm = std.fmt.bufPrint(&buf, "\x1b[{d};{d}s", .{ left, right }) catch return;
    proto.writeBufOrFail(posix.STDOUT_FILENO, slrm);

    // 4. Enable origin mode (cursor positioning relative to margins)
    proto.writeBufOrFail(posix.STDOUT_FILENO, "\x1b[?6h");

    // 5. Cursor home (now within the margin area)
    proto.writeBufOrFail(posix.STDOUT_FILENO, "\x1b[H");
}

fn teardownViewport() void {
    if (!viewport_active) return;
    viewport_active = false;
    const reset = "\x1b[?6l" ++ // disable origin mode
        "\x1b[?69l" ++ // disable DECLRMM
        "\x1b[r" ++ // reset DECSTBM
        "\x1b[H\x1b[2J"; // clear screen
    proto.writeBufOrFail(posix.STDOUT_FILENO, reset);
}

fn drawBorder(pad_left: u16, pad_top: u16, cols: u16, rows: u16) void {
    // Box-drawing characters (Unicode)
    const TL = "\xe2\x94\x8c"; // ┌
    const TR = "\xe2\x94\x90"; // ┐
    const BL = "\xe2\x94\x94"; // └
    const BR = "\xe2\x94\x98"; // ┘
    const H = "\xe2\x94\x80"; // ─
    const V = "\xe2\x94\x82"; // │

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    const border_left = pad_left; // 0-based column before content (border at pad_left, 1-based = pad_left)
    const border_top = pad_top; // 0-based row before content
    const border_right = pad_left + cols + 1; // 1-based column after content
    const border_bottom = pad_top + rows + 1; // 1-based row after content

    // Only draw border if there's room
    if (border_right > term_cols or border_bottom > term_rows) {
        // Not enough room for border, just fill background
        fillBackground(pad_left, pad_top, cols, rows);
        return;
    }

    // Top border: move to (border_top, border_left), draw ┌──...──┐
    const top_pos = std.fmt.bufPrint(buf[pos..], "\x1b[{d};{d}H", .{ border_top, border_left }) catch return;
    pos += top_pos.len;
    @memcpy(buf[pos .. pos + TL.len], TL);
    pos += TL.len;
    for (0..cols) |_| {
        if (pos + H.len > buf.len) break;
        @memcpy(buf[pos .. pos + H.len], H);
        pos += H.len;
    }
    @memcpy(buf[pos .. pos + TR.len], TR);
    pos += TR.len;

    proto.writeBufOrFail(posix.STDOUT_FILENO, buf[0..pos]);
    pos = 0;

    // Side borders
    for (0..rows) |r| {
        const row = border_top + 1 + @as(u16, @intCast(r));
        // Left border
        const left_pos = std.fmt.bufPrint(buf[pos..], "\x1b[{d};{d}H{s}", .{ row, border_left, V }) catch break;
        pos += left_pos.len;
        // Right border
        const right_pos = std.fmt.bufPrint(buf[pos..], "\x1b[{d};{d}H{s}", .{ row, border_right, V }) catch break;
        pos += right_pos.len;

        if (pos > buf.len - 64) {
            proto.writeBufOrFail(posix.STDOUT_FILENO, buf[0..pos]);
            pos = 0;
        }
    }

    // Bottom border: └──...──┘
    const bot_pos = std.fmt.bufPrint(buf[pos..], "\x1b[{d};{d}H", .{ border_bottom, border_left }) catch return;
    pos += bot_pos.len;
    @memcpy(buf[pos .. pos + BL.len], BL);
    pos += BL.len;
    for (0..cols) |_| {
        if (pos + H.len > buf.len) break;
        @memcpy(buf[pos .. pos + H.len], H);
        pos += H.len;
    }
    @memcpy(buf[pos .. pos + BR.len], BR);
    pos += BR.len;

    proto.writeBufOrFail(posix.STDOUT_FILENO, buf[0..pos]);

    // Fill empty areas outside the border with dim dots
    fillBackground(pad_left, pad_top, cols, rows);
}

fn fillBackground(_: u16, pad_top: u16, _: u16, rows: u16) void {
    // Fill areas outside the content area with dim middle-dot characters
    const DIM_ON = "\x1b[2m"; // dim
    const DIM_OFF = "\x1b[22m"; // normal intensity
    const DOT = "\xc2\xb7"; // ·

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    @memcpy(buf[pos .. pos + DIM_ON.len], DIM_ON);
    pos += DIM_ON.len;

    // Top empty rows
    for (0..pad_top) |r| {
        const row: u16 = @intCast(r + 1);
        const mv = std.fmt.bufPrint(buf[pos..], "\x1b[{d};1H", .{row}) catch break;
        pos += mv.len;
        for (0..term_cols) |_| {
            if (pos + DOT.len > buf.len - 64) {
                proto.writeBufOrFail(posix.STDOUT_FILENO, buf[0..pos]);
                pos = 0;
            }
            @memcpy(buf[pos .. pos + DOT.len], DOT);
            pos += DOT.len;
        }
    }

    // Bottom empty rows
    const content_bottom = pad_top + rows + 2; // +2 for border
    var r: u16 = content_bottom;
    while (r < term_rows) : (r += 1) {
        const mv = std.fmt.bufPrint(buf[pos..], "\x1b[{d};1H", .{r + 1}) catch break;
        pos += mv.len;
        for (0..term_cols) |_| {
            if (pos + DOT.len > buf.len - 64) {
                proto.writeBufOrFail(posix.STDOUT_FILENO, buf[0..pos]);
                pos = 0;
            }
            @memcpy(buf[pos .. pos + DOT.len], DOT);
            pos += DOT.len;
        }
    }

    @memcpy(buf[pos .. pos + DIM_OFF.len], DIM_OFF);
    pos += DIM_OFF.len;
    proto.writeBufOrFail(posix.STDOUT_FILENO, buf[0..pos]);
}

// APC sequence parser — scans for ESC _ ZTACH;cols;rows ESC \
// Returns the number of bytes consumed, and optionally the parsed pty size.
const ApcResult = struct {
    consumed: usize,
    cols: u16,
    rows: u16,
    found: bool,
};

fn parseApcSize(data: []const u8) ApcResult {
    const prefix = proto.APC_PREFIX;
    if (data.len < prefix.len + 3 + proto.APC_SUFFIX.len) {
        return .{ .consumed = 0, .cols = 0, .rows = 0, .found = false };
    }

    if (!std.mem.startsWith(u8, data, prefix)) {
        return .{ .consumed = 0, .cols = 0, .rows = 0, .found = false };
    }

    // Find the ST (ESC \) terminator
    const payload_start = prefix.len;
    var end: usize = payload_start;
    while (end + 1 < data.len) : (end += 1) {
        if (data[end] == '\x1b' and data[end + 1] == '\\') {
            // Parse "cols;rows"
            const payload = data[payload_start..end];
            const semi = std.mem.indexOfScalar(u8, payload, ';') orelse
                return .{ .consumed = end + 2, .cols = 0, .rows = 0, .found = false };
            const cols_str = payload[0..semi];
            const rows_str = payload[semi + 1 ..];
            const cols = std.fmt.parseInt(u16, cols_str, 10) catch
                return .{ .consumed = end + 2, .cols = 0, .rows = 0, .found = false };
            const rows = std.fmt.parseInt(u16, rows_str, 10) catch
                return .{ .consumed = end + 2, .cols = 0, .rows = 0, .found = false };
            return .{ .consumed = end + 2, .cols = cols, .rows = rows, .found = true };
        }
    }

    // No terminator found yet — might be split across reads
    return .{ .consumed = 0, .cols = 0, .rows = 0, .found = false };
}

/// Process incoming data from the socket, stripping APC size messages.
/// Writes non-APC data directly to stdout.
/// Suppresses pty output entirely when our terminal is too small.
fn processSocketData(data: []const u8) void {
    var i: usize = 0;
    var flush_start: usize = 0;

    while (i < data.len) {
        if (data[i] == '\x1b' and i + 1 < data.len and data[i + 1] == '_') {
            // Potential APC sequence — flush everything before it
            if (i > flush_start and !too_small) {
                proto.writeBufOrFail(posix.STDOUT_FILENO, data[flush_start..i]);
            }

            const result = parseApcSize(data[i..]);
            if (result.found) {
                pty_cols = result.cols;
                pty_rows = result.rows;
                setupViewport();
                i += result.consumed;
                flush_start = i;
                continue;
            } else if (result.consumed > 0) {
                i += result.consumed;
                flush_start = i;
                continue;
            }
        }
        i += 1;
    }

    // Flush remaining data (suppressed when too small)
    if (flush_start < data.len and !too_small) {
        proto.writeBufOrFail(posix.STDOUT_FILENO, data[flush_start..]);
    }
}

/// Scan buf[0..len] for focus event sequences (\x1b[I and \x1b[O).
/// For each found, send a .focus packet to the master. Strip the 3-byte
/// sequences from the buffer and return the remaining length.
fn stripFocusEvents(s: posix.fd_t, buf: []u8, len: usize) usize {
    if (len < 3) return len;

    var read_pos: usize = 0;
    var write_pos: usize = 0;

    while (read_pos < len) {
        if (read_pos + 2 < len and buf[read_pos] == '\x1b' and buf[read_pos + 1] == '[' and
            (buf[read_pos + 2] == 'I' or buf[read_pos + 2] == 'O'))
        {
            // Send .focus packet: len=1 for gained (I), len=0 for lost (O)
            var fpkt = Packet.zeroed();
            fpkt.type = .focus;
            fpkt.len = if (buf[read_pos + 2] == 'I') 1 else 0;
            proto.writePacketOrFail(s, &fpkt);

            // On focus gained, follow up with .winch so the server can
            // resize the PTY now that we own it.
            if (buf[read_pos + 2] == 'I') {
                fpkt.type = .winch;
                _ = std.c.ioctl(posix.STDIN_FILENO, TIOCGWINSZ, @intFromPtr(&fpkt.u.ws));
                proto.writePacketOrFail(s, &fpkt);
            }

            read_pos += 3;
        } else {
            buf[write_pos] = buf[read_pos];
            write_pos += 1;
            read_pos += 1;
        }
    }
    return write_pos;
}

fn processKbd(
    s: posix.fd_t,
    pkt: *Packet,
    no_suspend: bool,
    detach_char: i32,
    redraw_method: RedrawMethod,
) void {
    const VSUSP = @intFromEnum(posix.V.SUSP);
    if (!no_suspend and pkt.u.buf[0] == cur_term.cc[VSUSP]) {
        pkt.type = .detach;
        proto.writePacketOrFail(s, pkt);

        if (viewport_active) teardownViewport();
        posix.tcsetattr(posix.STDIN_FILENO, .DRAIN, orig_term_ptr.*) catch {};
        const msg1 = proto.EOS ++ "\r\n";
        _ = std.c.write(posix.STDOUT_FILENO, msg1.ptr, msg1.len);
        _ = std.c.kill(std.c.getpid(), posix.SIG.TSTP);
        posix.tcsetattr(posix.STDIN_FILENO, .DRAIN, cur_term) catch {};

        pkt.type = .attach;
        proto.writePacketOrFail(s, pkt);

        pkt.type = .redraw;
        pkt.len = @intFromEnum(redraw_method);
        _ = std.c.ioctl(posix.STDIN_FILENO, TIOCGWINSZ, @intFromPtr(&pkt.u.ws));
        proto.writePacketOrFail(s, pkt);
        return;
    }

    if (detach_char >= 0 and pkt.u.buf[0] == @as(u8, @intCast(@as(u32, @bitCast(detach_char))))) {
        restoreTerm();
        const msg = proto.EOS ++ "\r\n[detached]\r\n";
        _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
        std.c._exit(0);
    }

    if (pkt.u.buf[0] == '\x0c') {
        win_changed = true;
    }

    proto.writePacketOrFail(s, pkt);
}

pub fn attachMain(
    noerror: bool,
    sock_name: [:0]const u8,
    orig_term: *const posix.termios,
    detach_char: i32,
    no_suspend: bool,
    redraw_method: RedrawMethod,
) u8 {
    orig_term_ptr = orig_term;

    const s = connectSocket(sock_name) catch {
        if (!noerror) {
            const msg = "ztach: connection failed\n";
            _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
        }
        return 1;
    };

    cur_term = orig_term.*;

    // Signal handlers
    var sa: posix.Sigaction = std.mem.zeroes(posix.Sigaction);
    sa.handler = .{ .handler = die };
    sa.mask = posix.sigemptyset();
    sa.flags = 0;
    posix.sigaction(posix.SIG.HUP, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.QUIT, &sa, null);

    sa.handler = .{ .handler = winChange };
    posix.sigaction(posix.SIG.WINCH, &sa, null);

    sa.handler = .{ .handler = posix.SIG.IGN };
    posix.sigaction(posix.SIG.PIPE, &sa, null);

    // Set raw mode
    const IFlag = @typeInfo(posix.tc_iflag_t).@"struct".backing_integer.?;
    const OFlag = @typeInfo(posix.tc_oflag_t).@"struct".backing_integer.?;
    const LFlag = @typeInfo(posix.tc_lflag_t).@"struct".backing_integer.?;
    const CFlag = @typeInfo(posix.tc_cflag_t).@"struct".backing_integer.?;

    cur_term.iflag = @bitCast(@as(IFlag, @bitCast(cur_term.iflag)) & ~@as(IFlag, @bitCast(posix.tc_iflag_t{
        .IGNBRK = true,
        .BRKINT = true,
        .PARMRK = true,
        .ISTRIP = true,
        .INLCR = true,
        .IGNCR = true,
        .ICRNL = true,
        .IXON = true,
        .IXOFF = true,
    })));
    cur_term.oflag = @bitCast(@as(OFlag, @bitCast(cur_term.oflag)) & ~@as(OFlag, @bitCast(posix.tc_oflag_t{
        .OPOST = true,
    })));
    cur_term.lflag = @bitCast(@as(LFlag, @bitCast(cur_term.lflag)) & ~@as(LFlag, @bitCast(posix.tc_lflag_t{
        .ECHO = true,
        .ECHONL = true,
        .ICANON = true,
        .ISIG = true,
        .IEXTEN = true,
    })));
    cur_term.cflag = @bitCast(@as(CFlag, @bitCast(cur_term.cflag)) & ~@as(CFlag, @bitCast(posix.tc_cflag_t{
        .CSIZE = .CS8,
        .PARENB = true,
    })));
    cur_term.cflag.CSIZE = .CS8;
    cur_term.cc[@intFromEnum(posix.V.MIN)] = 1;
    cur_term.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(posix.STDIN_FILENO, .DRAIN, cur_term) catch {};

    // Clear screen and enable focus reporting (DECSET 1004)
    proto.writeBufOrFail(posix.STDOUT_FILENO, "\x1b[H\x1b[2J\x1b[?1004h");

    // Get initial terminal size
    getTermSize();

    // Send attach + redraw
    var pkt = Packet.zeroed();
    pkt.type = .attach;
    proto.writePacketOrFail(s, &pkt);

    pkt.type = .redraw;
    pkt.len = @intFromEnum(redraw_method);
    _ = std.c.ioctl(posix.STDIN_FILENO, TIOCGWINSZ, @intFromPtr(&pkt.u.ws));
    proto.writePacketOrFail(s, &pkt);

    // Main loop — use raw std.c.poll so SIGWINCH (EINTR) breaks out immediately
    var poll_fds = [_]std.c.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = std.c.POLL.IN, .revents = 0 },
        .{ .fd = s, .events = std.c.POLL.IN, .revents = 0 },
    };

    while (true) {
        poll_fds[0].revents = 0;
        poll_fds[1].revents = 0;

        const poll_rc = std.c.poll(&poll_fds, 2, -1);
        if (poll_rc < 0) {
            // EINTR from SIGWINCH — fall through to check win_changed
            if (std.c.errno(poll_rc) != .INTR) {
                restoreTerm();
                const msg = proto.EOS ++ "\r\n[poll failed]\r\n";
                _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
                std.c._exit(1);
            }
        }

        // Check window size FIRST — process immediately on SIGWINCH
        if (win_changed) {
            win_changed = false;
            pkt.type = .winch;
            _ = std.c.ioctl(posix.STDIN_FILENO, TIOCGWINSZ, @intFromPtr(&pkt.u.ws));
            proto.writePacketOrFail(s, &pkt);
            getTermSize();
            if (viewport_active) setupViewport();
        }

        // Socket activity (pty output + APC size messages)
        if (poll_fds[1].revents & std.c.POLL.IN != 0) {
            var buf: [proto.BUFSIZE]u8 = undefined;
            const len = posix.read(s, &buf) catch {
                restoreTerm();
                const msg = proto.EOS ++ "\r\n[read error]\r\n";
                _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
                std.c._exit(1);
            };
            if (len == 0) {
                restoreTerm();
                const msg = proto.EOS ++ "\r\n[EOF - ztach terminating]\r\n";
                _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
                std.c._exit(0);
            }
            processSocketData(buf[0..len]);
        }

        // Stdin activity (keyboard + focus events)
        if (poll_fds[0].revents & std.c.POLL.IN != 0) {
            pkt.type = .push;
            @memset(&pkt.u.buf, 0);
            const len = posix.read(posix.STDIN_FILENO, &pkt.u.buf) catch {
                restoreTerm();
                std.c._exit(1);
            };
            if (len == 0) {
                restoreTerm();
                std.c._exit(1);
            }
            // Strip focus events (\x1b[I / \x1b[O) and send .focus packets
            const remaining = stripFocusEvents(s, &pkt.u.buf, len);
            if (remaining > 0) {
                pkt.len = @intCast(remaining);
                processKbd(s, &pkt, no_suspend, detach_char, redraw_method);

                // Non-escape input means the server just marked us
                // active. Send .winch so it resizes the PTY to our
                // size. Stops once too_small clears from the APC.
                if (too_small and pkt.u.buf[0] != '\x1b') {
                    var wpkt = Packet.zeroed();
                    wpkt.type = .winch;
                    _ = std.c.ioctl(posix.STDIN_FILENO, TIOCGWINSZ, @intFromPtr(&wpkt.u.ws));
                    proto.writePacketOrFail(s, &wpkt);
                }
            }
        }
    }
    return 0;
}

pub fn pushMain(sock_name: [:0]const u8) u8 {
    const s = connectSocket(sock_name) catch {
        const msg = "ztach: connection failed\n";
        _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
        return 1;
    };

    var sa: posix.Sigaction = std.mem.zeroes(posix.Sigaction);
    sa.handler = .{ .handler = posix.SIG.IGN };
    sa.mask = posix.sigemptyset();
    sa.flags = 0;
    posix.sigaction(posix.SIG.PIPE, &sa, null);

    var pkt = Packet.zeroed();
    pkt.type = .push;

    while (true) {
        @memset(&pkt.u.buf, 0);
        const len = posix.read(posix.STDIN_FILENO, &pkt.u.buf) catch {
            const msg = "ztach: read error\n";
            _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
            return 1;
        };
        if (len == 0) return 0;

        pkt.len = @intCast(len);
        const pkt_bytes = pkt.asBytes();
        const wrc = std.c.write(s, pkt_bytes.ptr, pkt_bytes.len);
        if (wrc < 0 or @as(usize, @intCast(wrc)) != pkt_bytes.len) {
            const msg = "ztach: write error\n";
            _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
            return 1;
        }
    }
}
