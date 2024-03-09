//! Provides a canvas-like interface for drawing to the terminal. The methods
//! provided are not thread-safe.

// TODO: Resize terminal buffer and window to match canvas size
// TODO: Thread safety? (can probably get away without it)
// TODO: Add option to copy last frame to current frame
const std = @import("std");
const kernel32 = windows.kernel32;
const system = std.os.system;
const time = std.time;
const unicode = std.unicode;
const windows = std.os.windows;

const Allocator = std.mem.Allocator;
const ByteList = std.ArrayListUnmanaged(u8);
const File = std.fs.File;
const SIG = std.os.SIG;

pub const Animation = @import("Animation.zig");
pub const input = @import("input.zig");
const RingQueue = @import("ring_queue.zig").RingQueue(i64);
pub const View = @import("View.zig");

const assert = std.debug.assert;
const eql = std.meta.eql;
const sigaction = std.os.sigaction;

const IS_WINDOWS = @import("builtin").os.tag == .windows;
const ESC = "\x1B";
const CSI = ESC ++ "[";
const OSC = ESC ++ "]";
const ST = ESC ++ "\\";

var initialized = false;

pub var _allocator: Allocator = undefined;
var stdout: File = undefined;
var terminal_size: Size = undefined;
var draw_buffer: ByteList = undefined;

var last: Frame = undefined;
var current: Frame = undefined;
var should_redraw: bool = undefined;

var draw_times: RingQueue = undefined;

/// Closest 8-bit colors to Windows 10 Console's default 16, calculated using
/// CIELAB color space
///
/// https://en.wikipedia.org/wiki/ANSI_escape_code#Colors
pub const Color = enum(u8) {
    /// Not rendered (transperent)
    none = 0,
    black = 232,
    red = 124,
    green = 34,
    yellow = 178,
    blue = 20, // Originally 27, but IMO 20 looks better
    magenta = 90,
    cyan = 32,
    white = 252,
    bright_black = 243,
    bright_red = 203,
    bright_green = 40,
    bright_yellow = 229,
    bright_blue = 69,
    bright_magenta = 127,
    bright_cyan = 80,
    bright_white = 255,
};

pub const Size = struct {
    width: u16,
    height: u16,

    pub fn area(self: Size) u32 {
        return @as(u32, self.width) * @as(u32, self.height);
    }

    pub fn bound(self: Size, other: Size) Size {
        return .{
            .width = @min(self.width, other.width),
            .height = @min(self.height, other.height),
        };
    }

    pub fn bounded(self: Size, bigger: Size) bool {
        return self.width <= bigger.width and self.height <= bigger.height;
    }
};

pub const Pixel = struct {
    fg: Color,
    bg: Color,
    char: u21,
};

pub const Frame = struct {
    size: Size,
    pixels: []Pixel,

    pub fn init(allocator: Allocator, width: u16, height: u16) !Frame {
        const size = Size{ .width = width, .height = height };
        const pixels = try allocator.alloc(Pixel, size.area());
        var frame = Frame{ .size = size, .pixels = pixels };
        frame.fill(.{ .fg = Color.black, .bg = Color.black, .char = ' ' });
        return frame;
    }

    pub fn deinit(self: *Frame, allocator: Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn inBounds(self: Frame, x: u16, y: u16) bool {
        return x < self.size.width and y < self.size.height;
    }

    pub fn get(self: Frame, x: u16, y: u16) Pixel {
        assert(self.inBounds(x, y));
        const index = @as(usize, y) * self.size.width + x;
        return self.pixels[index];
    }

    pub fn set(self: *Frame, x: u16, y: u16, p: Pixel) void {
        assert(self.inBounds(x, y));
        const index = @as(usize, y) * self.size.width + x;
        self.pixels[index] = p;
    }

    pub fn copy(self: Frame, source: Frame) void {
        const copy_size = self.Size.bound(source.size);
        for (0..copy_size.height) |y| {
            for (0..copy_size.width) |x| {
                const p = source.get(@intCast(x), @intCast(y));
                self.set(@intCast(x), @intCast(y), p);
            }
        }
    }

    pub fn fill(self: *Frame, p: Pixel) void {
        for (self.pixels) |*pixel| {
            pixel.* = p;
        }
    }
};

const signal = if (IS_WINDOWS)
    struct {
        extern "c" fn signal(
            sig: c_int,
            func: *const fn (c_int, c_int) callconv(windows.WINAPI) void,
        ) callconv(.C) *anyopaque;
    }.signal
else
    void;

const setConsoleMode = if (IS_WINDOWS)
    struct {
        extern "kernel32" fn SetConsoleMode(
            console: windows.HANDLE,
            mode: windows.DWORD,
        ) callconv(windows.WINAPI) windows.BOOL;
    }.SetConsoleMode
else
    void;

pub const InitError = error{
    FailedToSetConsoleOutputCP,
    FailedToSetConsoleMode,
};
pub fn init(allocator: Allocator, fps_timing_window: usize, width: u16, height: u16) !void {
    if (initialized) {
        return;
    }
    initialized = true;
    errdefer initialized = false;

    _allocator = allocator;
    stdout = std.io.getStdOut();

    if (IS_WINDOWS) {
        _ = signal(SIG.INT, handleExitWindows);
    } else {
        const action = std.os.Sigaction{
            .handler = .{ .handler = handleExit },
            .mask = std.os.empty_sigset,
            .flags = 0,
        };
        std.os.sigaction(SIG.INT, &action, null) catch unreachable;
    }

    if (IS_WINDOWS) {
        const CP_UTF8 = 65001;
        const result = kernel32.SetConsoleOutputCP(CP_UTF8);
        if (system.getErrno(result) != .SUCCESS) {
            return InitError.FailedToSetConsoleOutputCP;
        }

        const ENABLE_PROCESSED_OUTPUT = 0x1;
        const ENABLE_WRAP_AT_EOL_OUTPUT = 0x2;
        const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x4;
        const ENABLE_LVB_GRID_WORLDWIDE = 0x10;
        const result2 = setConsoleMode(
            stdout.handle,
            ENABLE_PROCESSED_OUTPUT |
                ENABLE_WRAP_AT_EOL_OUTPUT |
                ENABLE_VIRTUAL_TERMINAL_PROCESSING |
                ENABLE_LVB_GRID_WORLDWIDE,
        );
        if (system.getErrno(result2) != .SUCCESS) {
            return InitError.FailedToSetConsoleMode;
        }
    }

    // Use a guess if we can't get the terminal size
    terminal_size = terminalSize() orelse Size{ .width = 120, .height = 30 };
    draw_buffer = ByteList{};

    last = try Frame.init(allocator, width, height);
    current = try Frame.init(allocator, width, height);

    draw_times = try RingQueue.init(allocator, fps_timing_window);
    draw_times.enqueue(time.microTimestamp()) catch {};

    useAlternateBuffer();
    hideCursor(stdout.writer()) catch {};

    should_redraw = true;
}

pub fn deinit() void {
    if (!initialized) {
        return;
    }
    initialized = false;

    useMainBuffer();
    showCursor(stdout.writer()) catch {};

    draw_buffer.deinit(_allocator);
    last.deinit(_allocator);
    current.deinit(_allocator);

    draw_times.deinit(_allocator);
}

fn handleExit(sig: c_int) callconv(.C) void {
    switch (sig) {
        // Handle interrupt
        SIG.INT => {
            deinit();
            std.process.exit(0);
        },
        else => unreachable,
    }
}

fn handleExitWindows(sig: c_int, _: c_int) callconv(.C) void {
    handleExit(sig);
}

pub fn terminalSize() ?Size {
    if (IS_WINDOWS) {
        return terminalSizeWindows();
    }

    if (!@hasDecl(system, "ioctl") or
        !@hasDecl(system, "T") or
        !@hasDecl(system.T, "IOCGWINSZ"))
    {
        @compileError("ioctl not available; cannot get terminal size.");
    }

    var size: system.winsize = undefined;
    const result = system.ioctl(
        std.os.STDOUT_FILENO,
        system.T.IOCGWINSZ,
        @intFromPtr(&size),
    );
    if (system.getErrno(result) != .SUCCESS) {
        return null;
    }

    return Size{
        .width = size.ws_col,
        .height = size.ws_row,
    };
}

fn terminalSizeWindows() ?Size {
    var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    const result = kernel32.GetConsoleScreenBufferInfo(stdout.handle, &info);
    if (system.getErrno(result) != .SUCCESS) {
        return null;
    }

    return Size{
        .width = @bitCast(info.dwSize.X),
        .height = @bitCast(info.dwSize.Y),
    };
}

// TODO
pub fn setTerminalSize(width: u16, height: u16) !void {
    should_redraw = true;

    if (IS_WINDOWS) {
        setTerminalSizeWindows(width, height);
    }

    // TODO: Implement for other platforms
    @compileError("setTerminalSize not implemented for this platform.");
}

// TODO
fn setTerminalSizeWindows(width: u16, height: u16) !void {
    _ = height;
    _ = width;
}

pub fn canvasSize() Size {
    return current.size;
}

pub fn setCanvasSize(width: u16, height: u16) !void {
    if (!initialized) {
        return;
    }

    should_redraw = true;

    last.deinit(_allocator);
    const old_current = current;
    defer old_current.deinit(_allocator);

    last = try Frame.init(_allocator, width, height);
    current = try Frame.init(_allocator, width, height);
    current.copy(old_current);

    setTerminalSize(width, height) catch {};
}

pub fn view() View {
    return View{
        .left = 0,
        .top = 0,
        .width = current.size.width,
        .height = current.size.height,
    };
}

pub fn fps() f64 {
    if (!initialized or draw_times.data.len == 0) {
        return 0;
    }
    assert(!draw_times.isEmpty());

    const elapsed: f64 = @floatFromInt(time.microTimestamp() - draw_times.peekIndex(0).?);
    return time.us_per_s * @as(f64, @floatFromInt(draw_times.len())) / elapsed;
}

pub fn fpsTimingWindow() usize {
    return draw_times.data.len;
}

pub fn setFpsTimingWindow(window: usize) !void {
    if (!initialized) {
        return;
    }

    var old_times = draw_times;
    defer old_times.deinit(_allocator);

    draw_times = try RingQueue.init(_allocator, window);
    while (old_times.dequeue()) |t| {
        draw_times.enqueue(t) catch break;
    }
}

pub fn setTitle(title: []const u8) void {
    stdout.writeAll(OSC ++ "0;") catch {};
    stdout.writeAll(title) catch {};
    stdout.writeAll(ST) catch {};
}

fn useAlternateBuffer() void {
    stdout.writeAll(CSI ++ "?1049h") catch {};
}

fn useMainBuffer() void {
    stdout.writeAll(CSI ++ "?1049l") catch {};
}

pub fn drawPixel(x: u16, y: u16, fg: Color, bg: Color, char: u21) void {
    if (!initialized) {
        return;
    }

    if (current.inBounds(x, y)) {
        const old = current.get(x, y);
        current.set(x, y, .{
            .fg = if (fg == Color.none) old.fg else fg,
            .bg = if (bg == Color.none) old.bg else bg,
            .char = char,
        });
    }
}

pub fn render() !void {
    if (!initialized) {
        return error.NotInitialized;
    }
    defer should_redraw = false;

    if (draw_times.data.len > 0) {
        if (draw_times.isFull()) {
            _ = draw_times.dequeue();
        }
        draw_times.enqueue(time.microTimestamp()) catch unreachable;
    }
    updateTerminalSize();

    const draw_size = current.size.bound(terminal_size);
    const writer = draw_buffer.writer(_allocator);
    const x_offset = @max(0, terminal_size.width - draw_size.width) / 2;
    const y_offset = @max(0, terminal_size.height - draw_size.height) / 2;

    if (should_redraw) {
        try clearScreen(writer);
        try hideCursor(writer);
    }

    var last_x: u16 = 0;
    var last_y: u16 = 0;
    try setCursorPos(writer, last_x + x_offset, last_y + y_offset);

    var last_fg = current.get(last_x, last_y).fg;
    var last_bg = current.get(last_x, last_y).bg;
    try setColor(writer, last_fg, last_bg);

    var diff_exists = false;
    var y: u16 = 0;
    while (y < draw_size.height) : (y += 1) {
        var x: u16 = 0;
        while (x < draw_size.width) : (x += 1) {
            const p = current.get(x, y);

            if (p.fg == Color.none or p.bg == Color.none) {
                continue;
            }
            if (!should_redraw and eql(p, last.get(x, y))) {
                continue;
            }
            diff_exists = true;

            if (x != last_x or y != last_y) {
                try setCursorPos(writer, x + x_offset, y + y_offset);
            }
            last_x = x + 1; // Add 1 to account for cursor movement
            last_y = y;

            if (p.fg != last_fg and p.bg != last_bg) {
                try setColor(writer, p.fg, p.bg);
            } else if (p.fg != last_fg) {
                try setForeColor(writer, p.fg);
            } else if (p.bg != last_bg) {
                try setBackColor(writer, p.bg);
            }
            last_fg = p.fg;
            last_bg = p.bg;

            var utf8_bytes: [4]u8 = undefined;
            const len = try unicode.utf8Encode(p.char, &utf8_bytes);
            try writer.writeAll(utf8_bytes[0..len]);
        }
    }

    // Reset colors at the end so that the area outside the canvas stays black
    try resetColors(writer);
    if (diff_exists) {
        stdout.writeAll(draw_buffer.items[0..draw_buffer.items.len]) catch {};
    }
    try advanceBuffers();
}

fn updateTerminalSize() void {
    const old_terminal_size = terminal_size;
    terminal_size = terminalSize() orelse terminal_size;
    if (!eql(terminal_size, old_terminal_size)) {
        should_redraw = true;
    }
}

fn advanceBuffers() !void {
    std.mem.swap(Frame, &last, &current);
    current.fill(.{ .fg = Color.black, .bg = Color.black, .char = ' ' });

    // Limit the size of the draw buffer to not waste memory
    const max_size = current.size.area() * 12;
    if (draw_buffer.items.len > max_size) {
        draw_buffer.clearAndFree(_allocator);
        try draw_buffer.ensureTotalCapacity(_allocator, max_size / 2);
    }
    draw_buffer.clearRetainingCapacity();
}

fn clearScreen(writer: anytype) !void {
    try writer.writeAll(CSI ++ "2J");
}

fn resetColors(writer: anytype) !void {
    try writer.writeAll(CSI ++ "m");
}

fn setColor(writer: anytype, fg: Color, bg: Color) !void {
    try writer.print(CSI ++ "38;5;{};48;5;{}m", .{ @intFromEnum(fg), @intFromEnum(bg) });
}

fn setForeColor(writer: anytype, fg: Color) !void {
    try writer.print(CSI ++ "38;5;{}m", .{@intFromEnum(fg)});
}

fn setBackColor(writer: anytype, bg: Color) !void {
    try writer.print(CSI ++ "48;5;{}m", .{@intFromEnum(bg)});
}

fn resetCursor(writer: anytype) !void {
    try writer.writeAll(CSI ++ "H");
}

fn setCursorPos(writer: anytype, x: u16, y: u16) !void {
    try writer.print(CSI ++ "{};{}H", .{ y + 1, x + 1 });
}

fn showCursor(writer: anytype) !void {
    try writer.writeAll(CSI ++ "?25h");
}

fn hideCursor(writer: anytype) !void {
    try writer.writeAll(CSI ++ "?25l");
}
