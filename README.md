# ztach

A terminal session multiplexer inspired by [dtach](https://github.com/crispy1989/dtach), rewritten in Zig. Detach and reattach to terminal sessions, with multi-client viewport support.

## What it does

- **Detach/reattach** to long-running terminal sessions (like dtach/screen/tmux)
- **Multi-client aware** — multiple clients can attach to the same session
- **Viewport rendering** — when your terminal is larger than the pty, content is centered with a border and VT100 hardware margins clip the output
- **Too-small detection** — when your terminal is smaller than the pty (e.g. phone while your computer is driving), output is suppressed and a status message is shown
- **Last-active sizing** — the pty always matches whichever client most recently resized or attached
- **Stale socket cleanup** — automatically reclaims dead sockets from crashed sessions
- **Zero allocations** — no heap usage at runtime

## Install

### Homebrew (macOS)

```bash
brew tap orderrrr/ztach
brew install ztach
```

### From source

Requires [Zig](https://ziglang.org/) master (0.14.1+):

```bash
git clone https://github.com/orderrrr/ztach.git
cd ztach
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/ztach ~/.local/bin/
```

## Usage

```
ztach -c <socket> <command>    # Create session + attach
ztach -n <socket> <command>    # Create session detached
ztach -a <socket>              # Attach to existing session
ztach -A <socket> <command>    # Attach or create if missing
ztach -p <socket>              # Pipe stdin to session
```

### Examples

```bash
# Start a detached shell session
ztach -n /tmp/work bash

# Attach to it
ztach -a /tmp/work

# Detach with Ctrl-\

# Create and immediately attach to neovim
ztach -c /tmp/editor nvim

# Attach with SIGWINCH-based redraw
ztach -a /tmp/editor -r winch
```

### Options

```
-e <char>     Set detach character (default: ^\)
-E            Disable detach character
-r <method>   Redraw method: none, ctrl_l, winch
-z            Disable suspend key processing
```

### Brewfile

```ruby
tap "orderrrr/ztach"
brew "ztach"
```

## How it works

ztach runs a master daemon that owns the pty and accepts client connections over a unix socket. Clients attach by connecting to the socket and forwarding keyboard input / receiving pty output.

When multiple clients are connected, the pty is sized to whichever client most recently resized or attached. Clients with a larger terminal see the content centered within VT100 margins (DECSTBM + DECLRMM + DECOM). Clients with a smaller terminal see a "session active on larger display" message instead of garbled output.

Size notifications are sent inline using APC escape sequences (`ESC _ ZTACH;cols;rows ESC \`), which are stripped by the client before reaching your terminal.

## License

MIT
