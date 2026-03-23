# ztach — 1:1 Port of dtach to Zig

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Port dtach (1,480 lines of C) to Zig as "ztach" with identical behavior, using `zig_openpty` for pty management.

**Architecture:** Same client-server model as dtach — master process manages a pty + child program and multiplexes I/O to attached clients over a Unix domain socket. Uses `poll()` instead of `select()` (functionally identical, idiomatic Zig). Links libc (required by `zig_openpty` on macOS). Zero heap allocations in steady state — all data structures use fixed-size stack/static buffers.

**Tech Stack:** Zig 0.16 (master), `zig_openpty` for forkpty/openpty, `std.posix` for sockets/poll/signals/terminal

**Target Platforms:** macOS + Linux

**Reference Code:** `inspo/dtach/` contains the original C source.

---

## Memory Strategy

Zero heap allocations after process startup. All buffers are fixed-size:

| Data Structure | Size | Rationale |
|----------------|------|-----------|
| Client array | `[256]Client` | dtach typically has 1-5 clients. 256 is generous. |
| Poll fd array | `[MAX_CLIENTS+2]pollfd` | One per client + server socket + pty fd |
| Read/write buffers | `[4096]u8` | Matches dtach's BUFSIZE |
| Command argv | `[256]?[*:0]const u8` | Stack buffer for exec |
| Exec argv ptrs | `[256]?[*:0]const u8` | Stack buffer for execvpeZ |

No `std.ArrayList`, no allocator parameters, no `deinit` calls. Swap-remove for O(1) client removal.

---

## File Map

```
ztach/
├── build.zig           -- build configuration
├── build.zig.zon       -- package manifest + zig_openpty dependency
├── inspo/dtach/        -- (existing) C reference code
└── src/
    ├── main.zig        -- entry point, arg parsing, mode dispatch
    ├── protocol.zig    -- packet types, message types, IO helpers
    ├── master.zig      -- master/daemon process (pty, clients, event loop)
    └── attach.zig      -- client attach + push mode
```

---

## Risks / Open Questions

1. **Zig 0.16 + zig_openpty compatibility** — zig_openpty targets 0.14+. Build API and `std.posix` surface may have changed. Task 1 includes a verification step. If it fails, vendor and patch.
2. **`std.c.environ`** — needed for `execvpeZ` in the child. Available when libc is linked.
3. **Signal handling** — Zig's `std.posix.sigaction` works but signal handlers are restricted to async-signal-safe operations only (same constraint as C).
4. **ioctl constants** — `TIOCGWINSZ`, `TIOCSWINSZ`, `TIOCGPGRP` values differ between macOS and Linux. May need to be sourced from `std.os.linux` / `std.c` or hardcoded with comptime platform check.
5. **termios flag types** — Zig 0.16 may use packed structs for `tc_iflag_t` etc. Bitwise ops may need `@bitCast`.

---

## Task 1: Project Scaffolding + Dependency Verification

**Files:**
- Create: `build.zig.zon`
- Create: `build.zig`
- Create: `src/main.zig` (minimal, verifies zig_openpty import)

**Step 1: Create `build.zig.zon`**

```zig
.{
    .name = .ztach,
    .version = "0.1.0",
    .fingerprint = .{},
    .minimum_zig_version = "0.14.0",
    .dependencies = .{
        .zig_openpty = .{
            .url = "https://github.com/PaNDa2code/zig_openpty/archive/refs/tags/v1.0.0.tar.gz",
            // hash will be populated by zig fetch
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

**Step 2: Fetch the dependency hash**

Run: `zig fetch --save https://github.com/PaNDa2code/zig_openpty/archive/refs/tags/v1.0.0.tar.gz`

This populates the `.hash` field. If it fails on 0.16, try: `https://github.com/PaNDa2code/zig_openpty/archive/master.tar.gz`

**Step 3: Create `build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_openpty_dep = b.dependency("zig_openpty", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ztach",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    exe.root_module.addImport("zig_openpty", zig_openpty_dep.module("openpty"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ztach");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_tests.root_module.addImport("zig_openpty", zig_openpty_dep.module("openpty"));

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
```

**Step 4: Create minimal `src/main.zig`**

```zig
const std = @import("std");
const pty = @import("zig_openpty");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("ztach - version 0.1.0\n", .{});
    // Verify zig_openpty imported successfully
    _ = pty.openpty;
    _ = pty.forkpty;
}
```

**Step 5: Build and verify**

Run: `zig build`
Expected: Clean compile, no errors.

Run: `./zig-out/bin/ztach`
Expected: Prints `ztach - version 0.1.0`

**Step 6: Commit**

```
git add build.zig build.zig.zon src/main.zig
git commit -m "scaffold: zig project with zig_openpty dependency"
```

---

## Task 2: Protocol Module

**Files:**
- Create: `src/protocol.zig`
- Modify: `src/main.zig` (import protocol to verify)

**Reference:** `inspo/dtach/dtach.h:101-141`, `inspo/dtach/main.c:48-89`

**Step 1: Create `src/protocol.zig`**

```zig
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
/// Port of dtach write_buf_or_fail (main.c:49-69)
pub fn writeBufOrFail(fd: posix.fd_t, buf: []const u8) void {
    var remaining = buf;
    while (remaining.len > 0) {
        const written = posix.write(fd, remaining) catch {
            _ = posix.write(posix.STDOUT_FILENO, EOS ++ "\r\n[write failed]\r\n") catch {};
            posix.exit(1);
        };
        remaining = remaining[written..];
    }
}

/// Write a full packet atomically. Exit process on failure.
/// Port of dtach write_packet_or_fail (main.c:73-89)
pub fn writePacketOrFail(fd: posix.fd_t, pkt: *const Packet) void {
    const bytes = pkt.asBytes();
    const written = posix.write(fd, bytes) catch {
        _ = posix.write(posix.STDOUT_FILENO, EOS ++ "\r\n[write failed]\r\n") catch {};
        posix.exit(1);
    };
    if (written != bytes.len) {
        _ = posix.write(posix.STDOUT_FILENO, EOS ++ "\r\n[write failed]\r\n") catch {};
        posix.exit(1);
    }
}
```

**Step 2: Import in main.zig to verify**

Add to `src/main.zig`:
```zig
const protocol = @import("protocol.zig");
// in main():
try stdout.print("Packet size: {d}\n", .{@sizeOf(protocol.Packet)});
```

**Step 3: Build and verify**

Run: `zig build`
Expected: Clean compile. Packet size should be 10 (1 + 1 + 8).

**Step 4: Commit**

```
git add src/protocol.zig src/main.zig
git commit -m "feat: add protocol types matching dtach wire format"
```

---

## Task 3: Master Process

Largest task. Ports `inspo/dtach/master.c` (824 lines). Zero heap allocations — fixed buffers for clients and poll fds.

**Files:**
- Create: `src/master.zig`

**Reference:** `inspo/dtach/master.c`

**Step 1: Create `src/master.zig`**

```zig
const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const pty_lib = @import("zig_openpty");
const proto = @import("protocol.zig");

const Packet = proto.Packet;
const MessageType = proto.MessageType;
const RedrawMethod = proto.RedrawMethod;

const MAX_CLIENTS = 256;

const Client = struct {
    fd: posix.fd_t,
    attached: bool,
};

const Pty = struct {
    fd: posix.fd_t,
    pid: posix.pid_t,
    term: posix.termios,
    ws: posix.winsize,
};

// Static state (matches C's file-scoped statics)
var the_pty: Pty = undefined;
var client_buf: [MAX_CLIENTS]Client = undefined;
var client_count: usize = 0;
var sock_name_global: [*:0]const u8 = undefined;

// ioctl constants — platform-specific
const TIOCSWINSZ: u32 = switch (builtin.os.tag) {
    .macos => 0x80087467,
    .linux => 0x5414,
    else => @compileError("unsupported OS"),
};
const TIOCGWINSZ: u32 = switch (builtin.os.tag) {
    .macos => 0x40087468,
    .linux => 0x5413,
    else => @compileError("unsupported OS"),
};
const TIOCGPGRP: u32 = switch (builtin.os.tag) {
    .macos => 0x40047477,
    .linux => 0x540F,
    else => @compileError("unsupported OS"),
};

fn unlinkSocket() callconv(.c) void {
    _ = std.c.unlink(sock_name_global);
}

/// Signal handler for SIGCHLD/SIGINT/SIGTERM
/// Port of master.c:69-82
fn die(sig: c_int) callconv(.c) void {
    if (sig == posix.SIG.CHLD) return;
    posix.exit(1);
}

fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(flags)) | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
}

fn addClient(fd: posix.fd_t) void {
    if (client_count >= MAX_CLIENTS) {
        posix.close(fd);
        return;
    }
    client_buf[client_count] = .{ .fd = fd, .attached = false };
    client_count += 1;
}

fn removeClient(index: usize) void {
    posix.close(client_buf[index].fd);
    client_buf[index] = client_buf[client_count - 1];
    client_count -= 1;
}

/// Port of master.c:107-149
fn initPty(argv: []const [:0]const u8, status_fd: posix.fd_t, orig_term: *const posix.termios, dont_have_tty: bool) !void {
    var term_ptr: ?*posix.termios = null;
    the_pty.term = orig_term.*;
    the_pty.ws = std.mem.zeroes(posix.winsize);

    if (!dont_have_tty) {
        term_ptr = &the_pty.term;
    }

    const pid = pty_lib.forkpty(&the_pty.fd, null, null, term_ptr, null) catch {
        return error.ForkPtyFailed;
    };

    if (pid == 0) {
        // Child: exec the command
        var argv_ptrs: [256]?[*:0]const u8 = .{null} ** 256;
        for (argv, 0..) |arg, i| {
            if (i >= 255) break;
            argv_ptrs[i] = arg.ptr;
        }

        const env = @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));
        const err = posix.execvpeZ(argv[0].ptr, @ptrCast(&argv_ptrs), env);
        _ = err;

        // exec failed
        if (status_fd >= 0) {
            posix.dup2(status_fd, posix.STDOUT_FILENO) catch {};
        } else {
            _ = posix.write(posix.STDOUT_FILENO, proto.EOS ++ "\r\n") catch {};
        }
        _ = posix.write(posix.STDOUT_FILENO, "ztach: could not execute command\r\n") catch {};
        posix.exit(1);
    }

    the_pty.pid = pid;
}

/// Send signal to pty's process group
/// Port of master.c:152-178
fn killPty(sig: c_int) void {
    var pgrp: posix.pid_t = -1;
    const rc = std.c.ioctl(the_pty.fd, TIOCGPGRP, &pgrp);
    if (rc >= 0 and pgrp > 0) {
        _ = std.c.kill(-pgrp, sig);
        return;
    }
    _ = std.c.kill(-the_pty.pid, sig);
}

/// Port of master.c:181-227
fn createSocket(name: [:0]const u8) !posix.socket_t {
    if (name.len > 104 - 1) return error.NameTooLong;

    const old_umask = std.c.umask(0o077);

    const s = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(s);

    var addr = std.net.Address.initUnix(name) catch return error.NameTooLong;
    posix.bind(s, &addr.any, addr.getOsSockLen()) catch |err| {
        _ = std.c.umask(old_umask);
        return err;
    };
    _ = std.c.umask(old_umask);

    try posix.listen(s, 128);
    try setNonBlocking(s);
    _ = std.c.chmod(name.ptr, 0o600);

    return s;
}

/// Port of master.c:230-246
fn updateSocketModes(has_client: bool) void {
    var st: std.c.Stat = undefined;
    if (std.c.stat(sock_name_global, &st) < 0) return;

    const new_mode: std.c.mode_t = if (has_client)
        st.mode | 0o100
    else
        st.mode & ~@as(std.c.mode_t, 0o100);

    if (st.mode != new_mode) {
        _ = std.c.chmod(sock_name_global, new_mode);
    }
}

/// Port of master.c:250-339
/// Reads pty output and writes to all attached clients.
/// Uses fixed buffer for poll fds — zero allocations.
fn ptyActivity(server_fd: posix.fd_t) void {
    var buf: [proto.BUFSIZE]u8 = undefined;

    const len = posix.read(the_pty.fd, &buf) catch {
        const result = std.c.waitpid(the_pty.pid, null, 0);
        _ = result;
        posix.exit(1);
    };
    if (len == 0) {
        _ = std.c.waitpid(the_pty.pid, null, 0);
        posix.exit(1);
    }

    // Get current terminal settings
    the_pty.term = posix.tcgetattr(the_pty.fd) catch {
        posix.exit(1);
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
                const w = posix.write(pfd.fd, buf[written..len]) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => {
                        had_error = true;
                        break;
                    },
                };
                written += w;
            }
            if (!had_error and written == len) n_written += 1;
        }

        // Done if server socket active or wrote to at least one client
        if (write_fds[0].revents & posix.POLL.IN != 0 or n_written > 0) break;
        // Otherwise retry (matches C's goto top)
    }
}

/// Port of master.c:342-367
fn controlActivity(server_fd: posix.fd_t) void {
    const fd = posix.accept(server_fd, null, null) catch return;
    setNonBlocking(fd) catch {
        posix.close(fd);
        return;
    };
    addClient(fd);
}

/// Port of master.c:370-446
/// Returns true if the client was removed (caller should not increment index).
fn clientActivity(index: usize, redraw: RedrawMethod) bool {
    var pkt: Packet = undefined;
    const pkt_bytes = std.mem.asBytes(&pkt);

    const len = posix.read(client_buf[index].fd, pkt_bytes) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => {
            removeClient(index);
            return true;
        },
    };

    if (len != @sizeOf(Packet)) {
        removeClient(index);
        return true;
    }

    switch (pkt.type) {
        .push => {
            if (pkt.len <= pkt.u.buf.len) {
                proto.writeBufOrFail(the_pty.fd, pkt.u.buf[0..pkt.len]);
            }
        },
        .attach => {
            client_buf[index].attached = true;
        },
        .detach => {
            client_buf[index].attached = false;
        },
        .winch => {
            the_pty.ws = pkt.u.ws;
            _ = std.c.ioctl(the_pty.fd, TIOCSWINSZ, &the_pty.ws);
        },
        .redraw => {
            var method: RedrawMethod = @enumFromInt(@as(u2, @truncate(pkt.len)));
            if (method == .unspec) method = redraw;

            the_pty.ws = pkt.u.ws;
            _ = std.c.ioctl(the_pty.fd, TIOCSWINSZ, &the_pty.ws);

            if (method == .ctrl_l) {
                // Send ^L if terminal is in no-echo, character-at-a-time mode
                // Check c_lflag for ECHO and ICANON being off
                const lflag = @as(u32, @bitCast(the_pty.term.lflag));
                const echo_canon = @as(u32, @bitCast(posix.tc_lflag_t{ .ECHO = true, .ICANON = true }));
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

/// Main event loop for the master process.
/// Port of master.c:450-567
/// Zero allocations in the hot loop — all fixed buffers.
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
    _ = std.c.atexit(unlinkSocket);

    // Signal handlers
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = die },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.CHLD, &sa, null) catch {};
    posix.sigaction(posix.SIG.INT, &sa, null) catch {};
    posix.sigaction(posix.SIG.TERM, &sa, null) catch {};

    sa.handler = .{ .handler = posix.SIG.IGN };
    posix.sigaction(posix.SIG.PIPE, &sa, null) catch {};
    posix.sigaction(posix.SIG.HUP, &sa, null) catch {};
    posix.sigaction(posix.SIG.TTIN, &sa, null) catch {};
    posix.sigaction(posix.SIG.TTOU, &sa, null) catch {};

    initPty(argv, status_fd, orig_term, dont_have_tty) catch {
        posix.exit(1);
    };

    if (status_fd >= 0) posix.close(status_fd);

    // Redirect stdio to /dev/null
    const null_fd = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch {
        posix.exit(1);
    };
    posix.dup2(null_fd, posix.STDIN_FILENO) catch {};
    posix.dup2(null_fd, posix.STDOUT_FILENO) catch {};
    posix.dup2(null_fd, posix.STDERR_FILENO) catch {};
    if (null_fd > 2) posix.close(null_fd);

    client_count = 0;
    var waiting = wait_attach;
    var has_attached: bool = false;

    // Fixed buffer for poll fds — zero allocations per iteration
    var poll_fds: [MAX_CLIENTS + 2]posix.pollfd = undefined;

    while (true) {
        var n_fds: usize = 0;

        // Always watch the server socket
        poll_fds[n_fds] = .{ .fd = server_fd, .events = posix.POLL.IN, .revents = 0 };
        n_fds += 1;

        // Watch pty if not waiting for initial attach
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

        // Watch all client fds
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

        _ = posix.poll(poll_fds[0..n_fds], -1) catch |err| switch (err) {
            error.Interrupted => continue,
            else => posix.exit(1),
        };

        // New client?
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            controlActivity(server_fd);
        }

        // Client activity?
        {
            var i: usize = 0;
            while (i < client_count) {
                const pfd_idx = client_poll_start + i;
                if (pfd_idx < n_fds and poll_fds[pfd_idx].revents & posix.POLL.IN != 0) {
                    if (clientActivity(i, redraw)) continue; // removed, don't increment
                }
                i += 1;
            }
        }

        // Pty activity?
        if (pty_poll_idx) |idx| {
            if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                ptyActivity(server_fd);
            }
        }
    }
}

/// Entry point for master mode.
/// Port of master.c:569-689
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
        // TODO: ENAMETOOLONG chdir workaround (port master.c:582-607)
        const stderr = std.io.getStdErr().writer();
        stderr.print("ztach: {s}: could not create socket\n", .{sock_name}) catch {};
        return 1;
    };

    _ = posix.fcntl(s, posix.F.SETFD, @as(u32, posix.FD_CLOEXEC)) catch {};

    // Error-reporting pipe
    var status_fd: posix.fd_t = -1;
    if (dont_fork) {
        status_fd = posix.dup(posix.STDERR_FILENO) catch -1;
        if (status_fd >= 0) {
            _ = posix.fcntl(status_fd, posix.F.SETFD, @as(u32, posix.FD_CLOEXEC)) catch {
                posix.close(status_fd);
                status_fd = -1;
            };
        }
        masterProcess(s, argv, wait_attach, status_fd, orig_term, dont_have_tty, redraw_method.*);
        return 0;
    }

    var pipe_fds: [2]posix.fd_t = .{ -1, -1 };
    if (posix.pipe()) |fds| {
        pipe_fds = fds;
        _ = posix.fcntl(pipe_fds[0], posix.F.SETFD, @as(u32, posix.FD_CLOEXEC)) catch {};
        _ = posix.fcntl(pipe_fds[1], posix.F.SETFD, @as(u32, posix.FD_CLOEXEC)) catch {};
    } else |_| {}

    const pid = posix.fork() catch {
        const stderr = std.io.getStdErr().writer();
        stderr.print("ztach: fork failed\n", .{}) catch {};
        unlinkSocket();
        return 1;
    };

    if (pid == 0) {
        // Child becomes master
        if (pipe_fds[0] >= 0) posix.close(pipe_fds[0]);
        masterProcess(s, argv, wait_attach, pipe_fds[1], orig_term, dont_have_tty, redraw_method.*);
        posix.exit(0);
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
```

**Step 2: Verify compilation**

Add `_ = @import("master.zig");` to main.zig temporarily to force compilation check.

Run: `zig build`
Expected: Clean compile.

**Step 3: Commit**

```
git add src/master.zig
git commit -m "feat: port master process from dtach (zero-alloc event loop)"
```

---

## Task 4: Attach + Push Module

**Files:**
- Create: `src/attach.zig`

**Reference:** `inspo/dtach/attach.c`

**Step 1: Create `src/attach.zig`**

```zig
const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const proto = @import("protocol.zig");

const Packet = proto.Packet;
const RedrawMethod = proto.RedrawMethod;

// ioctl constants
const TIOCGWINSZ: u32 = switch (builtin.os.tag) {
    .macos => 0x40087468,
    .linux => 0x5413,
    else => @compileError("unsupported OS"),
};

// Mutable state
var cur_term: posix.termios = undefined;
var win_changed: bool = false;
var orig_term_ptr: *const posix.termios = undefined;

fn restoreTerm() callconv(.c) void {
    posix.tcsetattr(posix.STDIN_FILENO, .DRAIN, orig_term_ptr.*) catch {};
    _ = posix.write(posix.STDOUT_FILENO, "\x1b[?25h") catch {};
}

fn die(sig: c_int) callconv(.c) void {
    if (sig == posix.SIG.HUP or sig == posix.SIG.INT) {
        _ = posix.write(posix.STDOUT_FILENO, proto.EOS ++ "\r\n[detached]\r\n") catch {};
    } else {
        _ = posix.write(posix.STDOUT_FILENO, proto.EOS ++ "\r\n[got signal - dying]\r\n") catch {};
    }
    posix.exit(1);
}

fn winChange(_: c_int) callconv(.c) void {
    win_changed = true;
}

fn connectSocket(name: [:0]const u8) !posix.fd_t {
    if (name.len > 104 - 1) return error.NameTooLong;

    const s = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(s);

    var addr = try std.net.Address.initUnix(name);
    try posix.connect(s, &addr.any, addr.getOsSockLen());
    return s;
}

/// Port of attach.c:106-145
fn processKbd(
    s: posix.fd_t,
    pkt: *Packet,
    no_suspend: bool,
    detach_char: i32,
    redraw_method: RedrawMethod,
) void {
    // Suspend key?
    const VSUSP = @intFromEnum(posix.V.SUSP);
    if (!no_suspend and pkt.u.buf[0] == cur_term.cc[VSUSP]) {
        pkt.type = .detach;
        proto.writePacketOrFail(s, pkt);

        posix.tcsetattr(posix.STDIN_FILENO, .DRAIN, orig_term_ptr.*) catch {};
        _ = posix.write(posix.STDOUT_FILENO, proto.EOS ++ "\r\n") catch {};
        _ = std.c.kill(std.c.getpid(), posix.SIG.TSTP);
        posix.tcsetattr(posix.STDIN_FILENO, .DRAIN, cur_term) catch {};

        pkt.type = .attach;
        proto.writePacketOrFail(s, pkt);

        pkt.type = .redraw;
        pkt.len = @intFromEnum(redraw_method);
        _ = std.c.ioctl(posix.STDIN_FILENO, TIOCGWINSZ, &pkt.u.ws);
        proto.writePacketOrFail(s, pkt);
        return;
    }

    // Detach char?
    if (detach_char >= 0 and pkt.u.buf[0] == @as(u8, @intCast(@as(u32, @bitCast(detach_char))))) {
        _ = posix.write(posix.STDOUT_FILENO, proto.EOS ++ "\r\n[detached]\r\n") catch {};
        posix.exit(0);
    }

    // Ctrl-L forces redraw
    if (pkt.u.buf[0] == '\x0c') {
        win_changed = true;
    }

    proto.writePacketOrFail(s, pkt);
}

/// Port of attach.c:148-297
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
        // TODO: ENAMETOOLONG chdir workaround (port attach.c:158-183)
        if (!noerror) {
            const stderr = std.io.getStdErr().writer();
            stderr.print("ztach: {s}: connection failed\n", .{sock_name}) catch {};
        }
        return 1;
    };

    cur_term = orig_term.*;
    _ = std.c.atexit(restoreTerm);

    // Signal handlers
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = die },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.HUP, &sa, null) catch {};
    posix.sigaction(posix.SIG.TERM, &sa, null) catch {};
    posix.sigaction(posix.SIG.INT, &sa, null) catch {};
    posix.sigaction(posix.SIG.QUIT, &sa, null) catch {};

    sa.handler = .{ .handler = winChange };
    posix.sigaction(posix.SIG.WINCH, &sa, null) catch {};

    sa.handler = .{ .handler = posix.SIG.IGN };
    posix.sigaction(posix.SIG.PIPE, &sa, null) catch {};

    // Set raw mode — port of attach.c:209-218
    cur_term.iflag &= ~@as(posix.tc_iflag_t, .{
        .IGNBRK = true, .BRKINT = true, .PARMRK = true,
        .ISTRIP = true, .INLCR = true, .IGNCR = true,
        .ICRNL = true, .IXON = true, .IXOFF = true,
    });
    cur_term.oflag &= ~@as(posix.tc_oflag_t, .{ .OPOST = true });
    cur_term.lflag &= ~@as(posix.tc_lflag_t, .{
        .ECHO = true, .ECHONL = true, .ICANON = true,
        .ISIG = true, .IEXTEN = true,
    });
    cur_term.cflag &= ~@as(posix.tc_cflag_t, .{ .CSIZE = true, .PARENB = true });
    cur_term.cflag |= @as(posix.tc_cflag_t, .{ .CS8 = true });
    cur_term.cc[@intFromEnum(posix.V.MIN)] = 1;
    cur_term.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(posix.STDIN_FILENO, .DRAIN, cur_term) catch {};

    // Clear screen (VT100)
    proto.writeBufOrFail(posix.STDOUT_FILENO, "\x1b[H\x1b[J");

    // Send attach + redraw
    var pkt = Packet.zeroed();
    pkt.type = .attach;
    proto.writePacketOrFail(s, &pkt);

    pkt.type = .redraw;
    pkt.len = @intFromEnum(redraw_method);
    _ = std.c.ioctl(posix.STDIN_FILENO, TIOCGWINSZ, &pkt.u.ws);
    proto.writePacketOrFail(s, &pkt);

    // Main loop — fixed 2-fd poll, zero allocations
    var poll_fds = [_]posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = s, .events = posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        poll_fds[0].revents = 0;
        poll_fds[1].revents = 0;

        _ = posix.poll(&poll_fds, -1) catch |err| switch (err) {
            error.Interrupted => continue,
            else => {
                _ = posix.write(posix.STDOUT_FILENO, proto.EOS ++ "\r\n[poll failed]\r\n") catch {};
                posix.exit(1);
            },
        };

        // Socket activity (pty output)
        if (poll_fds[1].revents & posix.POLL.IN != 0) {
            var buf: [proto.BUFSIZE]u8 = undefined;
            const len = posix.read(s, &buf) catch {
                _ = posix.write(posix.STDOUT_FILENO, proto.EOS ++ "\r\n[read error]\r\n") catch {};
                posix.exit(1);
            };
            if (len == 0) {
                _ = posix.write(posix.STDOUT_FILENO, proto.EOS ++ "\r\n[EOF - ztach terminating]\r\n") catch {};
                posix.exit(0);
            }
            proto.writeBufOrFail(posix.STDOUT_FILENO, buf[0..len]);
        }

        // Stdin activity (keyboard)
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            pkt.type = .push;
            @memset(&pkt.u.buf, 0);
            const len = posix.read(posix.STDIN_FILENO, &pkt.u.buf) catch {
                posix.exit(1);
            };
            if (len == 0) posix.exit(1);
            pkt.len = @intCast(len);
            processKbd(s, &pkt, no_suspend, detach_char, redraw_method);
        }

        // Window size changed?
        if (win_changed) {
            win_changed = false;
            pkt.type = .winch;
            _ = std.c.ioctl(posix.STDIN_FILENO, TIOCGWINSZ, &pkt.u.ws);
            proto.writePacketOrFail(s, &pkt);
        }
    }
    return 0;
}

/// Port of attach.c:300-372
pub fn pushMain(sock_name: [:0]const u8) u8 {
    const s = connectSocket(sock_name) catch {
        const stderr = std.io.getStdErr().writer();
        stderr.print("ztach: {s}: connection failed\n", .{sock_name}) catch {};
        return 1;
    };

    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sa, null) catch {};

    var pkt = Packet.zeroed();
    pkt.type = .push;

    while (true) {
        @memset(&pkt.u.buf, 0);
        const len = posix.read(posix.STDIN_FILENO, &pkt.u.buf) catch {
            const stderr = std.io.getStdErr().writer();
            stderr.print("ztach: read error\n", .{}) catch {};
            return 1;
        };
        if (len == 0) return 0;

        pkt.len = @intCast(len);
        const pkt_bytes = pkt.asBytes();
        const written = posix.write(s, pkt_bytes) catch {
            const stderr = std.io.getStdErr().writer();
            stderr.print("ztach: write error\n", .{}) catch {};
            return 1;
        };
        if (written != pkt_bytes.len) {
            const stderr = std.io.getStdErr().writer();
            stderr.print("ztach: write error\n", .{}) catch {};
            return 1;
        }
    }
}
```

**Step 2: Build to verify**

Run: `zig build`
Expected: Clean compile.

**Step 3: Commit**

```
git add src/attach.zig
git commit -m "feat: port attach + push mode from dtach (zero-alloc event loops)"
```

---

## Task 5: Main Entry Point

**Files:**
- Rewrite: `src/main.zig`

**Reference:** `inspo/dtach/main.c:129-332`

**Step 1: Rewrite `src/main.zig`**

```zig
const std = @import("std");
const posix = std.posix;
const proto = @import("protocol.zig");
const master = @import("master.zig");
const attach = @import("attach.zig");

const RedrawMethod = proto.RedrawMethod;

fn usage() noreturn {
    const msg =
        \\ztach - version {s}
        \\Usage: ztach -a <socket> <options>
        \\       ztach -A <socket> <options> <command...>
        \\       ztach -c <socket> <options> <command...>
        \\       ztach -n <socket> <options> <command...>
        \\       ztach -N <socket> <options> <command...>
        \\       ztach -p <socket>
        \\Modes:
        \\  -a        Attach to the specified socket.
        \\  -A        Attach to the specified socket, or create it if it
        \\              does not exist, running the specified command.
        \\  -c        Create a new socket and run the specified command.
        \\  -n        Create a new socket and run the specified command detached.
        \\  -N        Create a new socket and run the specified command detached,
        \\              and have ztach run in the foreground.
        \\  -p        Copy the contents of standard input to the specified socket.
        \\Options:
        \\  -e <char> Set the detach character to <char>, defaults to ^\.
        \\  -E        Disable the detach character.
        \\  -r <method> Set the redraw method to <method>. Valid methods:
        \\               none: Don't redraw at all.
        \\             ctrl_l: Send a Ctrl L character to the program.
        \\              winch: Send a WINCH signal to the program.
        \\  -z        Disable processing of the suspend key.
        \\
    ;
    const stdout = std.io.getStdOut().writer();
    stdout.print(msg, .{proto.VERSION}) catch {};
    posix.exit(0);
}

pub fn main() u8 {
    var detach_char: i32 = '\\' - 64; // Ctrl-backslash
    var no_suspend: bool = false;
    var redraw_method: RedrawMethod = .unspec;
    var orig_term: posix.termios = undefined;
    var dont_have_tty: bool = false;

    var args_iter = std.process.args();
    _ = args_iter.next(); // skip program name

    // Parse mode
    const mode_arg = args_iter.next() orelse {
        const stderr = std.io.getStdErr().writer();
        stderr.print("ztach: No mode was specified.\nTry 'ztach --help' for more information.\n", .{}) catch {};
        return 1;
    };

    if (std.mem.eql(u8, mode_arg, "--help") or
        std.mem.eql(u8, mode_arg, "-h") or
        std.mem.eql(u8, mode_arg, "-?"))
    {
        usage();
    }
    if (std.mem.eql(u8, mode_arg, "--version")) {
        const stdout = std.io.getStdOut().writer();
        stdout.print("ztach - version {s}\n", .{proto.VERSION}) catch {};
        return 0;
    }

    if (mode_arg.len != 2 or mode_arg[0] != '-') {
        const stderr = std.io.getStdErr().writer();
        stderr.print("ztach: Invalid mode '{s}'\n", .{mode_arg}) catch {};
        return 1;
    }

    const mode = mode_arg[1];
    if (mode != 'a' and mode != 'A' and mode != 'c' and
        mode != 'n' and mode != 'N' and mode != 'p')
    {
        const stderr = std.io.getStdErr().writer();
        stderr.print("ztach: Invalid mode '-{c}'\n", .{mode}) catch {};
        return 1;
    }

    // Parse socket name
    const sock_name: [:0]const u8 = args_iter.next() orelse {
        const stderr = std.io.getStdErr().writer();
        stderr.print("ztach: No socket was specified.\n", .{}) catch {};
        return 1;
    };

    // Push mode takes no further args
    if (mode == 'p') {
        return attach.pushMain(sock_name);
    }

    // Parse options and collect command args — fixed buffer, no allocator
    var cmd_args: [256][:0]const u8 = undefined;
    var cmd_count: usize = 0;
    var parsing_opts = true;

    while (args_iter.next()) |arg| {
        if (parsing_opts and arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--")) {
                parsing_opts = false;
                continue;
            }
            var i: usize = 1;
            while (i < arg.len) : (i += 1) {
                switch (arg[i]) {
                    'E' => detach_char = -1,
                    'z' => no_suspend = true,
                    'e' => {
                        const escape = args_iter.next() orelse {
                            const stderr = std.io.getStdErr().writer();
                            stderr.print("ztach: No escape character specified.\n", .{}) catch {};
                            return 1;
                        };
                        if (escape.len >= 2 and escape[0] == '^') {
                            detach_char = if (escape[1] == '?') 0x7f else escape[1] & 0x1f;
                        } else if (escape.len >= 1) {
                            detach_char = escape[0];
                        }
                        break;
                    },
                    'r' => {
                        const method_str = args_iter.next() orelse {
                            const stderr = std.io.getStdErr().writer();
                            stderr.print("ztach: No redraw method specified.\n", .{}) catch {};
                            return 1;
                        };
                        if (std.mem.eql(u8, method_str, "none")) {
                            redraw_method = .none;
                        } else if (std.mem.eql(u8, method_str, "ctrl_l")) {
                            redraw_method = .ctrl_l;
                        } else if (std.mem.eql(u8, method_str, "winch")) {
                            redraw_method = .winch;
                        } else {
                            const stderr = std.io.getStdErr().writer();
                            stderr.print("ztach: Invalid redraw method.\n", .{}) catch {};
                            return 1;
                        }
                        break;
                    },
                    else => {
                        const stderr = std.io.getStdErr().writer();
                        stderr.print("ztach: Invalid option '-{c}'\n", .{arg[i]}) catch {};
                        return 1;
                    },
                }
            }
        } else {
            parsing_opts = false;
            if (cmd_count < 256) {
                cmd_args[cmd_count] = arg;
                cmd_count += 1;
            }
        }
    }

    // Modes other than 'a' require a command
    if (mode != 'a' and cmd_count < 1) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("ztach: No command was specified.\n", .{}) catch {};
        return 1;
    }

    // Save original terminal settings
    orig_term = posix.tcgetattr(posix.STDIN_FILENO) catch {
        orig_term = std.mem.zeroes(posix.termios);
        dont_have_tty = true;
        orig_term; // need this for the catch to return the zeroed value
    };

    if (dont_have_tty and mode != 'n' and mode != 'N') {
        const stderr = std.io.getStdErr().writer();
        stderr.print("ztach: Attaching to a session requires a terminal.\n", .{}) catch {};
        return 1;
    }

    const cmd = cmd_args[0..cmd_count];

    return switch (mode) {
        'a' => {
            if (cmd_count > 0) {
                const stderr = std.io.getStdErr().writer();
                stderr.print("ztach: Invalid number of arguments.\n", .{}) catch {};
                return 1;
            }
            return attach.attachMain(false, sock_name, &orig_term, detach_char, no_suspend, redraw_method);
        },
        'n' => master.masterMain(cmd, false, false, sock_name, &redraw_method, &orig_term, dont_have_tty),
        'N' => master.masterMain(cmd, false, true, sock_name, &redraw_method, &orig_term, dont_have_tty),
        'c' => {
            if (master.masterMain(cmd, true, false, sock_name, &redraw_method, &orig_term, dont_have_tty) != 0) {
                return 1;
            }
            return attach.attachMain(false, sock_name, &orig_term, detach_char, no_suspend, redraw_method);
        },
        'A' => {
            const ret = attach.attachMain(true, sock_name, &orig_term, detach_char, no_suspend, redraw_method);
            if (ret != 0) {
                if (master.masterMain(cmd, true, false, sock_name, &redraw_method, &orig_term, dont_have_tty) != 0) {
                    return 1;
                }
                return attach.attachMain(false, sock_name, &orig_term, detach_char, no_suspend, redraw_method);
            }
            return 0;
        },
        else => 1,
    };
}
```

**Step 2: Build**

Run: `zig build`
Expected: Clean compile with all modules linked.

**Step 3: Commit**

```
git add src/main.zig
git commit -m "feat: port main entry point and arg parsing from dtach"
```

---

## Task 6: Build, Fix, and Integration Test

This is the debug-and-fix task. Expect compilation errors from Zig 0.16 API differences.

**Step 1: Full build**

Run: `zig build 2>&1`

Likely fix areas:
- `posix.Sigaction` struct layout / handler field type
- `posix.tc_iflag_t` / `tc_lflag_t` — may be packed structs needing different bitwise ops
- `posix.POLL.IN` / `POLL.OUT` — verify enum/struct field names
- `posix.pipe()` return type — may return a struct, not array
- `std.c.Stat` — field name may be `st_mode` not `mode`
- `posix.empty_sigset` — may not exist, use `std.mem.zeroes(posix.sigset_t)` instead
- `posix.FD_CLOEXEC` — may need `@as(u32, 1)` or similar
- `std.c.environ` — verify accessible on 0.16

**Step 2: Manual test — create detached session**

```bash
./zig-out/bin/ztach -n /tmp/ztach-test bash
```

Expected: Returns immediately, socket file exists at `/tmp/ztach-test`.

**Step 3: Manual test — attach**

```bash
./zig-out/bin/ztach -a /tmp/ztach-test
```

Expected: Drops into bash. Ctrl-\ detaches with `[detached]` message.

**Step 4: Manual test — reattach**

```bash
./zig-out/bin/ztach -a /tmp/ztach-test
```

Expected: Reconnects to same session, previous state visible.

**Step 5: Manual test — create + attach**

```bash
./zig-out/bin/ztach -c /tmp/ztach-test2 bash
```

Expected: Enters bash immediately. Ctrl-\ detaches.

**Step 6: Manual test — push mode**

```bash
echo "ls" | ./zig-out/bin/ztach -p /tmp/ztach-test
```

Expected: Sends "ls" to the session.

**Step 7: Manual test — window resize**

Attach to a session, resize terminal. Run `tput cols; tput lines` inside — should reflect new size.

**Step 8: Compare with dtach**

Build C dtach and run same tests side-by-side:
```bash
cd inspo/dtach && ./configure && make
./dtach -c /tmp/dtach-test bash
```

**Step 9: Commit**

```
git add -A
git commit -m "feat: ztach 0.1.0 - complete 1:1 port of dtach to zig"
```

---

## Known TODOs for Post-1:1 Work

These are explicitly deferred. Not needed for behavioral parity:

1. **ENAMETOOLONG chdir workaround** — `master.c:582-607` and `attach.c:158-183`. Only matters for very long socket paths. Port if needed.
2. **Solaris/AIX portability** — `BROKEN_MASTER`, STREAMS `I_PUSH`, AIX `/dev/ptc`. Not targeting these platforms.
3. **`RETSIGTYPE`** — C compatibility for systems where signal handlers return `int`. Not relevant in Zig.
4. **Better error messages** — Include `strerror` equivalent (`std.posix.errnoDescription`) in error output.
5. **Replace `posix.exit()` calls** — Consider proper error return propagation instead of hard exits, for future library use.
