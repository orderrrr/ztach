const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const proto = @import("protocol.zig");

const Packet = proto.Packet;
const MessageType = proto.MessageType;
const RedrawMethod = proto.RedrawMethod;

const MAX_CLIENTS = 256;

const Client = struct {
    fd: posix.fd_t,
    attached: bool,
    ws: posix.winsize,
};

const Pty = struct {
    fd: posix.fd_t,
    pid: std.c.pid_t,
    term: posix.termios,
    ws: posix.winsize,
};

extern "c" fn atexit(func: *const fn () callconv(.c) void) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

// libc forkpty — available on macOS (<util.h>) and Linux (<pty.h>)
extern "c" fn forkpty(
    master: *posix.fd_t,
    name: ?[*:0]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) std.c.pid_t;

// Static state
var the_pty: Pty = undefined;
var client_buf: [MAX_CLIENTS]Client = undefined;
var client_count: usize = 0;
var sock_name_global: [*:0]const u8 = undefined;
var active_client_fd: posix.fd_t = -1;

// ioctl constants — platform-specific, cast to c_int via @bitCast for ioctl()
const TIOCSWINSZ: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(c_uint, 0x80087467)),
    .linux => 0x5414,
    else => @compileError("unsupported OS"),
};
const TIOCGWINSZ: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(c_uint, 0x40087468)),
    .linux => 0x5413,
    else => @compileError("unsupported OS"),
};
const TIOCGPGRP: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(c_uint, 0x40047477)),
    .linux => 0x540F,
    else => @compileError("unsupported OS"),
};

fn unlinkSocket() callconv(.c) void {
    _ = std.c.unlink(sock_name_global);
}

fn die(_: posix.SIG) callconv(.c) void {
    std.c._exit(1);
}

fn dieChld(_: posix.SIG) callconv(.c) void {
    // SIGCHLD: do nothing, just reap in the main loop
}

fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags < 0) return error.FcntlFailed;
    const o_nonblock: c_uint = @bitCast(std.c.O{ .NONBLOCK = true });
    const rc = std.c.fcntl(fd, std.c.F.SETFL, @as(c_uint, @bitCast(flags)) | o_nonblock);
    if (rc < 0) return error.FcntlFailed;
}

fn addClient(fd: posix.fd_t) void {
    if (client_count >= MAX_CLIENTS) {
        posix.close(fd);
        return;
    }
    client_buf[client_count] = .{
        .fd = fd,
        .attached = false,
        .ws = std.mem.zeroes(posix.winsize),
    };
    client_count += 1;
}

fn removeClient(index: usize) void {
    posix.close(client_buf[index].fd);
    client_buf[index] = client_buf[client_count - 1];
    client_count -= 1;
}

/// Set pty to the given client's size and notify all clients.
fn setPtySize(ws: posix.winsize) void {
    if (ws.col == 0 or ws.row == 0) return;

    the_pty.ws = ws;
    _ = std.c.ioctl(the_pty.fd, TIOCSWINSZ, @intFromPtr(&the_pty.ws));
    killPty(posix.SIG.WINCH);
    notifyAllClients();
}

/// Force a full redraw by bouncing the pty through 1x1.
/// The delay ensures the child handles the first SIGWINCH (real change)
/// before the second one restores the correct size.
fn forceRedraw(ws: posix.winsize) void {
    if (ws.col == 0 or ws.row == 0) return;

    // Shrink to 1x1 — guarantees a visible size change
    var tiny: posix.winsize = std.mem.zeroes(posix.winsize);
    tiny.col = 1;
    tiny.row = 1;
    _ = std.c.ioctl(the_pty.fd, TIOCSWINSZ, @intFromPtr(&tiny));
    killPty(posix.SIG.WINCH);

    // Let the child process the first SIGWINCH
    const delay = std.c.timespec{ .sec = 0, .nsec = 5_000_000 }; // 5ms
    _ = std.c.nanosleep(&delay, null);

    // Restore real size — child redraws at correct dimensions
    setPtySize(ws);
}

fn notifyAllClients() void {
    for (client_buf[0..client_count]) |client| {
        if (!client.attached) continue;
        proto.writeSizeNotification(client.fd, the_pty.ws.col, the_pty.ws.row);
    }
}

fn initPty(argv: []const [:0]const u8, status_fd: posix.fd_t, orig_term: *const posix.termios, dont_have_tty: bool) !void {
    the_pty.term = orig_term.*;
    the_pty.ws = std.mem.zeroes(posix.winsize);

    var term_ptr: ?*const posix.termios = null;
    if (!dont_have_tty) {
        term_ptr = &the_pty.term;
    }

    const pid = forkpty(&the_pty.fd, null, term_ptr, null);

    if (pid < 0) return error.ForkPtyFailed;

    if (pid == 0) {
        // Child: exec the command
        var argv_ptrs: [256]?[*:0]const u8 = .{null} ** 256;
        for (argv, 0..) |arg, i| {
            if (i >= 255) break;
            argv_ptrs[i] = @ptrCast(arg.ptr);
        }

        _ = execvp(@ptrCast(argv[0].ptr), @ptrCast(&argv_ptrs));

        // exec failed
        if (status_fd >= 0) {
            _ = std.c.dup2(status_fd, posix.STDOUT_FILENO);
        } else {
            const msg = proto.EOS ++ "\r\n";
            _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
        }
        const msg = "ztach: could not execute command\r\n";
        _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
        std.c._exit(1);
    }

    the_pty.pid = pid;
}

fn killPty(sig: posix.SIG) void {
    var pgrp: std.c.pid_t = -1;
    const rc = std.c.ioctl(the_pty.fd, TIOCGPGRP, @intFromPtr(&pgrp));
    if (rc >= 0 and pgrp > 0) {
        _ = std.c.kill(-pgrp, sig);
        return;
    }
    _ = std.c.kill(-the_pty.pid, sig);
}

fn buildSockAddr(name: [:0]const u8) struct { addr: std.c.sockaddr.un, len: std.c.socklen_t } {
    var addr: std.c.sockaddr.un = std.mem.zeroes(std.c.sockaddr.un);
    addr.family = std.c.AF.UNIX;
    const name_bytes: []const u8 = name;
    @memcpy(addr.path[0..name_bytes.len], name_bytes);
    const addr_len: std.c.socklen_t = @intCast(@sizeOf(std.c.sa_family_t) + name_bytes.len + 1);
    return .{ .addr = addr, .len = addr_len };
}

fn createSocket(name: [:0]const u8) !posix.fd_t {
    if (name.len > 104 - 1) return error.NameTooLong;

    const old_umask = std.c.umask(0o077);

    const s = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (s < 0) {
        _ = std.c.umask(old_umask);
        return error.SocketFailed;
    }
    errdefer posix.close(s);

    const sa = buildSockAddr(name);
    var rc = std.c.bind(s, @ptrCast(&sa.addr), sa.len);
    if (rc < 0) {
        // Bind failed — check if the socket is stale (no one listening)
        const probe = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (probe >= 0) {
            const crc = std.c.connect(probe, @ptrCast(&sa.addr), sa.len);
            posix.close(probe);
            if (crc < 0) {
                // Connection refused = stale socket, unlink and retry
                _ = std.c.unlink(name.ptr);
                rc = std.c.bind(s, @ptrCast(&sa.addr), sa.len);
            }
        }
        if (rc < 0) {
            _ = std.c.umask(old_umask);
            return error.BindFailed;
        }
    }
    _ = std.c.umask(old_umask);

    const lrc = std.c.listen(s, 128);
    if (lrc < 0) return error.ListenFailed;
    try setNonBlocking(s);
    _ = std.c.chmod(name.ptr, 0o600);

    return s;
}

fn updateSocketModes(has_client: bool) void {
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(posix.AT.FDCWD, sock_name_global, &st, 0) < 0) return;

    const cur_mode: std.c.mode_t = st.mode;
    const new_mode: std.c.mode_t = if (has_client)
        cur_mode | 0o100
    else
        cur_mode & ~@as(std.c.mode_t, 0o100);

    if (cur_mode != new_mode) {
        _ = std.c.chmod(sock_name_global, new_mode);
    }
}

fn ptyActivity(server_fd: posix.fd_t) void {
    var buf: [proto.BUFSIZE]u8 = undefined;

    const rrc = posix.read(the_pty.fd, &buf) catch {
        _ = std.c.waitpid(the_pty.pid, null, 0);
        std.c._exit(1);
    };
    if (rrc == 0) {
        _ = std.c.waitpid(the_pty.pid, null, 0);
        std.c._exit(1);
    }
    const len = rrc;

    // Get current terminal settings
    the_pty.term = posix.tcgetattr(the_pty.fd) catch {
        std.c._exit(1);
    };

    // Fixed buffer for write-readiness poll
    var write_fds: [MAX_CLIENTS + 1]posix.pollfd = undefined;

    while (true) {
        var n: usize = 0;

        // Watch server socket for new connections
        write_fds[n] = .{ .fd = server_fd, .events = posix.POLL.IN, .revents = 0 };
        n += 1;

        var n_attached: usize = 0;
        for (client_buf[0..client_count]) |client| {
            if (!client.attached) continue;
            write_fds[n] = .{ .fd = client.fd, .events = posix.POLL.OUT, .revents = 0 };
            n += 1;
            n_attached += 1;
        }
        if (n_attached == 0) return;

        _ = posix.poll(write_fds[0..n], -1) catch return;

        // Write data to writable clients
        var n_written: usize = 0;
        for (write_fds[1..n]) |pfd| {
            if (pfd.revents & posix.POLL.OUT == 0) continue;

            var written: usize = 0;
            var had_error = false;
            while (written < len) {
                const wrc = std.c.write(pfd.fd, buf[written..len].ptr, len - written);
                if (wrc < 0) {
                    const e = std.c.errno(wrc);
                    if (e == .AGAIN) break;
                    had_error = true;
                    break;
                }
                written += @as(usize, @intCast(wrc));
            }
            if (!had_error and written == len) n_written += 1;
        }

        // Done if server socket active or wrote to at least one client
        if (write_fds[0].revents & posix.POLL.IN != 0 or n_written > 0) break;
    }
}

fn controlActivity(server_fd: posix.fd_t) void {
    const fd = std.c.accept(server_fd, null, null);
    if (fd < 0) return;
    setNonBlocking(fd) catch {
        posix.close(fd);
        return;
    };
    addClient(fd);
}

fn clientActivity(index: usize, redraw: RedrawMethod) bool {
    var pkt: Packet = undefined;
    const pkt_bytes = std.mem.asBytes(&pkt);

    const rrc = posix.read(client_buf[index].fd, pkt_bytes) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => {
            removeClient(index);
            return true;
        },
    };

    if (rrc != @sizeOf(Packet)) {
        removeClient(index);
        return true;
    }

    switch (pkt.type) {
        .push => {
            if (pkt.len <= pkt.u.buf.len) {
                proto.writeBufOrFail(the_pty.fd, pkt.u.buf[0..pkt.len]);
            }
            // Switch active client on non-escape input only.
            // Mouse events, terminal auto-responses, and escape
            // sequences all start with 0x1b — ignore those to
            // prevent feedback loops from forceRedraw output.
            const client_fd = client_buf[index].fd;
            if (client_fd != active_client_fd and pkt.u.buf[0] != 0x1b) {
                active_client_fd = client_fd;
                const cws = client_buf[index].ws;
                if (cws.col > 0 and cws.row > 0 and
                    (cws.col != the_pty.ws.col or cws.row != the_pty.ws.row))
                {
                    forceRedraw(cws);
                }
            }
        },
        .attach => {
            client_buf[index].attached = true;
            // Send current pty size to newly attached client
            if (the_pty.ws.col > 0 and the_pty.ws.row > 0) {
                proto.writeSizeNotification(client_buf[index].fd, the_pty.ws.col, the_pty.ws.row);
            }
        },
        .detach => {
            client_buf[index].attached = false;
        },
        .winch => {
            client_buf[index].ws = pkt.u.ws;
            setPtySize(pkt.u.ws);
        },
        .redraw => {
            var method: RedrawMethod = @enumFromInt(@as(u2, @truncate(pkt.len)));
            if (method == .unspec) method = redraw;

            client_buf[index].ws = pkt.u.ws;
            setPtySize(pkt.u.ws);

            if (method == .ctrl_l) {
                const LFlag = @typeInfo(posix.tc_lflag_t).@"struct".backing_integer.?;
                const lflag = @as(LFlag, @bitCast(the_pty.term.lflag));
                const echo_canon = @as(LFlag, @bitCast(posix.tc_lflag_t{ .ECHO = true, .ICANON = true }));
                if ((lflag & echo_canon) == 0 and the_pty.term.cc[@intFromEnum(posix.V.MIN)] == 1) {
                    proto.writeBufOrFail(the_pty.fd, "\x0c");
                }
            } else if (method == .winch) {
                killPty(posix.SIG.WINCH);
            }
        },
    }
    return false;
}

fn masterProcess(
    server_fd: posix.fd_t,
    argv: []const [:0]const u8,
    wait_attach: bool,
    status_fd: posix.fd_t,
    orig_term: *const posix.termios,
    dont_have_tty: bool,
    redraw: RedrawMethod,
) void {
    _ = std.c.setsid();
    _ = atexit(unlinkSocket);

    // Signal handlers
    var sa: posix.Sigaction = std.mem.zeroes(posix.Sigaction);
    sa.handler = .{ .handler = dieChld };
    sa.mask = posix.sigemptyset();
    sa.flags = 0;
    posix.sigaction(posix.SIG.CHLD, &sa, null);

    sa.handler = .{ .handler = die };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);

    sa.handler = .{ .handler = posix.SIG.IGN };
    posix.sigaction(posix.SIG.PIPE, &sa, null);
    posix.sigaction(posix.SIG.HUP, &sa, null);

    initPty(argv, status_fd, orig_term, dont_have_tty) catch {
        std.c._exit(1);
    };

    if (status_fd >= 0) posix.close(status_fd);

    // Redirect stdio to /dev/null
    const null_fd = posix.openat(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0) catch {
        std.c._exit(1);
    };
    _ = std.c.dup2(null_fd, posix.STDIN_FILENO);
    _ = std.c.dup2(null_fd, posix.STDOUT_FILENO);
    _ = std.c.dup2(null_fd, posix.STDERR_FILENO);
    if (null_fd > 2) posix.close(null_fd);

    client_count = 0;
    var waiting = wait_attach;
    var has_attached: bool = false;

    var poll_fds: [MAX_CLIENTS + 2]posix.pollfd = undefined;

    while (true) {
        var n_fds: usize = 0;

        poll_fds[n_fds] = .{ .fd = server_fd, .events = posix.POLL.IN, .revents = 0 };
        n_fds += 1;

        if (waiting) {
            if (client_count > 0 and client_buf[0].attached) {
                waiting = false;
            }
        }
        var pty_poll_idx: ?usize = null;
        if (!waiting) {
            pty_poll_idx = n_fds;
            poll_fds[n_fds] = .{ .fd = the_pty.fd, .events = posix.POLL.IN, .revents = 0 };
            n_fds += 1;
        }

        var new_has_attached = false;
        const client_poll_start = n_fds;
        for (client_buf[0..client_count]) |client| {
            poll_fds[n_fds] = .{ .fd = client.fd, .events = posix.POLL.IN, .revents = 0 };
            n_fds += 1;
            if (client.attached) new_has_attached = true;
        }

        if (has_attached != new_has_attached) {
            updateSocketModes(new_has_attached);
            has_attached = new_has_attached;
        }

        _ = posix.poll(poll_fds[0..n_fds], -1) catch {
            std.c._exit(1);
        };

        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            controlActivity(server_fd);
        }

        {
            var i: usize = 0;
            while (i < client_count) {
                const pfd_idx = client_poll_start + i;
                if (pfd_idx < n_fds and poll_fds[pfd_idx].revents & posix.POLL.IN != 0) {
                    if (clientActivity(i, redraw)) continue;
                }
                i += 1;
            }
        }

        if (pty_poll_idx) |idx| {
            if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                ptyActivity(server_fd);
            }
        }
    }
}

pub fn masterMain(
    argv: []const [:0]const u8,
    wait_attach: bool,
    dont_fork: bool,
    sock_name: [:0]const u8,
    redraw_method: *RedrawMethod,
    orig_term: *const posix.termios,
    dont_have_tty: bool,
) u8 {
    if (redraw_method.* == .unspec) redraw_method.* = .ctrl_l;

    sock_name_global = sock_name.ptr;

    const s = createSocket(sock_name) catch {
        const msg = "ztach: could not create socket\n";
        _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
        return 1;
    };

    _ = std.c.fcntl(s, std.c.F.SETFD, @as(c_uint, posix.FD_CLOEXEC));

    var status_fd: posix.fd_t = -1;
    if (dont_fork) {
        status_fd = std.c.dup(posix.STDERR_FILENO);
        if (status_fd >= 0) {
            const rc = std.c.fcntl(status_fd, std.c.F.SETFD, @as(c_uint, posix.FD_CLOEXEC));
            if (rc < 0) {
                posix.close(status_fd);
                status_fd = -1;
            }
        }
        masterProcess(s, argv, wait_attach, status_fd, orig_term, dont_have_tty, redraw_method.*);
        return 0;
    }

    var pipe_fds: [2]posix.fd_t = .{ -1, -1 };
    if (std.c.pipe(&pipe_fds) == 0) {
        _ = std.c.fcntl(pipe_fds[0], std.c.F.SETFD, @as(c_uint, posix.FD_CLOEXEC));
        _ = std.c.fcntl(pipe_fds[1], std.c.F.SETFD, @as(c_uint, posix.FD_CLOEXEC));
    }

    const pid = std.c.fork();
    if (pid < 0) {
        const msg = "ztach: fork failed\n";
        _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
        unlinkSocket();
        return 1;
    }

    if (pid == 0) {
        // Child becomes master
        if (pipe_fds[0] >= 0) posix.close(pipe_fds[0]);
        masterProcess(s, argv, wait_attach, pipe_fds[1], orig_term, dont_have_tty, redraw_method.*);
        std.c._exit(0);
    }

    // Parent: check for exec errors via pipe
    if (pipe_fds[0] >= 0) {
        posix.close(pipe_fds[1]);
        var err_buf: [1024]u8 = undefined;
        while (true) {
            const n = posix.read(pipe_fds[0], &err_buf) catch break;
            if (n == 0) break;
            proto.writeBufOrFail(posix.STDERR_FILENO, err_buf[0..n]);
            _ = std.c.kill(pid, posix.SIG.TERM);
            posix.close(pipe_fds[0]);
            return 1;
        }
        posix.close(pipe_fds[0]);
    }

    posix.close(s);
    return 0;
}
