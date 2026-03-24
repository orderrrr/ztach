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
    // Print using std.c.write — we can format at comptime since VERSION is comptime
    const formatted = std.fmt.comptimePrint(msg, .{proto.VERSION});
    _ = std.c.write(posix.STDOUT_FILENO, formatted.ptr, formatted.len);
    std.c._exit(0);
}

fn writeStderr(msg: []const u8) void {
    _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var detach_char: i32 = '\\' - 64; // Ctrl-backslash
    var no_suspend: bool = false;
    var redraw_method: RedrawMethod = .unspec;
    var orig_term: posix.termios = undefined;
    var dont_have_tty: bool = false;

    var args_iter = std.process.Args.Iterator.init(init.args);
    _ = args_iter.next(); // skip program name

    const mode_arg = args_iter.next() orelse {
        writeStderr("ztach: No mode was specified.\nTry 'ztach --help' for more information.\n");
        return 1;
    };

    if (std.mem.eql(u8, mode_arg, "--help") or
        std.mem.eql(u8, mode_arg, "-h") or
        std.mem.eql(u8, mode_arg, "-?"))
    {
        usage();
    }
    if (std.mem.eql(u8, mode_arg, "--version")) {
        const msg = "ztach - version " ++ proto.VERSION ++ "\n";
        _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
        return 0;
    }

    if (mode_arg.len != 2 or mode_arg[0] != '-') {
        writeStderr("ztach: Invalid mode\n");
        return 1;
    }

    const mode = mode_arg[1];
    if (mode != 'a' and mode != 'A' and mode != 'c' and
        mode != 'n' and mode != 'N' and mode != 'p')
    {
        writeStderr("ztach: Invalid mode\n");
        return 1;
    }

    const sock_name: [:0]const u8 = args_iter.next() orelse {
        writeStderr("ztach: No socket was specified.\n");
        return 1;
    };

    if (mode == 'p') {
        return attach.pushMain(sock_name);
    }

    // Parse options and collect command args
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
                            writeStderr("ztach: No escape character specified.\n");
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
                            writeStderr("ztach: No redraw method specified.\n");
                            return 1;
                        };
                        if (std.mem.eql(u8, method_str, "none")) {
                            redraw_method = .none;
                        } else if (std.mem.eql(u8, method_str, "ctrl_l")) {
                            redraw_method = .ctrl_l;
                        } else if (std.mem.eql(u8, method_str, "winch")) {
                            redraw_method = .winch;
                        } else {
                            writeStderr("ztach: Invalid redraw method.\n");
                            return 1;
                        }
                        break;
                    },
                    else => {
                        writeStderr("ztach: Invalid option\n");
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

    if (mode != 'a' and cmd_count < 1) {
        writeStderr("ztach: No command was specified.\n");
        return 1;
    }

    // Save original terminal settings
    var raw_term: std.c.termios = undefined;
    if (std.c.tcgetattr(posix.STDIN_FILENO, &raw_term) == 0) {
        orig_term = @bitCast(raw_term);
    } else {
        dont_have_tty = true;
        orig_term = std.mem.zeroes(posix.termios);
    }

    if (dont_have_tty and mode != 'n' and mode != 'N') {
        writeStderr("ztach: Attaching to a session requires a terminal.\n");
        return 1;
    }

    const cmd = cmd_args[0..cmd_count];

    return switch (mode) {
        'a' => {
            if (cmd_count > 0) {
                writeStderr("ztach: Invalid number of arguments.\n");
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
