//! Provides a canvas-like interface for drawing to the terminal. The methods
//! provided are not thread-safe.

pub const Animation = @import("Animation.zig");
pub const input = @import("input.zig");
pub const PeriodicTrigger = @import("PeriodicTrigger.zig");
pub const View = @import("View.zig");

// TODO: Thread safety? (can probably get away without it)
// TODO: Add option to copy last frame to current frame
const std = @import("std");
const Allocator = std.mem.Allocator;
const ByteList = std.ArrayListUnmanaged(u8);
const File = std.fs.File;
const kernel32 = windows.kernel32;
const linux = std.os.linux;
const SIG = linux.SIG;
const unicode = std.unicode;
const windows = std.os.windows;

const assert = std.debug.assert;
const eql = std.meta.eql;

const os_tag = @import("builtin").os.tag;
const ESC = "\x1B";
const CSI = ESC ++ "[";
const OSC = ESC ++ "]";
const ST = ESC ++ "\\";

// The exit handler runs on another thread so this variable needs to be atomic
// to prevent double frees. The rest of this struct however is not thread-safe.
var initialized: bool = false;

pub var _allocator: Allocator = undefined;
var _stdout: File = undefined;
var terminal_size: Size = undefined;
var draw_buffer: ByteList = undefined;

var last_frame: Frame = undefined;
var current_frame: Frame = undefined;
var should_redraw: bool = undefined;
var _null_fg_color: ?Color = undefined;
var _null_bg_color: ?Color = undefined;

pub const Color = u8;
/// Closest 8-bit colors to Windows 10 Console's default 16, calculated using
/// CIELAB color space (https://en.wikipedia.org/wiki/ANSI_escape_code#Colors)
pub const Colors = struct {
    pub const BLACK: Color = 232;
    pub const RED: Color = 124;
    pub const GREEN: Color = 34;
    pub const YELLOW: Color = 178;
    pub const BLUE: Color = 20; // Originally 27, but IMO 20 looks better.
    pub const MAGENTA: Color = 90;
    pub const CYAN: Color = 32;
    pub const WHITE: Color = 252;
    pub const BRIGHT_BLACK: Color = 243;
    pub const BRIGHT_RED: Color = 203;
    pub const BRIGHT_GREEN: Color = 40;
    pub const BRIGHT_YELLOW: Color = 229;
    pub const BRIGHT_BLUE: Color = 69;
    pub const BRIGHT_MAGENTA: Color = 127;
    pub const BRIGHT_CYAN: Color = 80;
    pub const BRIGHT_WHITE: Color = 255;
};

/// A 2D size with width and height.
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

/// A single pixel on the canvas.
pub const Pixel = struct {
    /// Foreground color. If `null`, `null_color` is used.
    fg: ?Color,
    /// Background color. If `null`, `null_color` is used.
    bg: ?Color,
    /// Unicode codepoint to display.
    char: u21,

    /// Returns the pixel that will be actually drawn to the screen.
    pub fn resolve(self: Pixel) Pixel {
        return .{
            .fg = self.fg orelse _null_fg_color,
            .bg = self.bg orelse _null_bg_color,
            .char = self.char,
        };
    }
};

/// Represents the state of the canvas at a given point in time.
pub const Frame = struct {
    size: Size,
    pixels: []Pixel,

    pub fn init(allocator: Allocator, width: u16, height: u16) !Frame {
        const size = Size{ .width = width, .height = height };
        const pixels = try allocator.alloc(Pixel, size.area());
        var frame = Frame{ .size = size, .pixels = pixels };
        frame.fill(.{ .fg = null, .bg = null, .char = ' ' });
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

    pub fn copy(self: *Frame, source: Frame) void {
        const copy_size = self.size.bound(source.size);
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

pub const InitError = error{
    FailedToSetConsoleOutputCP,
    FailedToSetConsoleMode,
};

/// Initializes the terminal canvas. This function must be called before any
/// other functions in this module. Fails silently if the canvas is already
/// initialized.
///
/// `allocator` - The allocator to use for memory allocation.
///
/// `stdout` - The standard output file to write to.
///
/// `fps_timing_window` - The number of frames to average over when calculating
/// the frames per second.
///
/// `width` - The width of the canvas in pixels.
///
/// `height` - The height of the canvas in pixels.
///
/// `null_fg_color` - The color to default to when the foreground color is `null`.
/// If `null`, the terminal's default foreground color is used.
///
/// `null_bg_color` - The color to default to when the background color is `null`.
/// If `null`, there is no background color (essentially transparent).
pub fn init(
    allocator: Allocator,
    stdout: File,
    width: u16,
    height: u16,
    null_fg_color: ?Color,
    null_bg_color: ?Color,
) !void {
    if (initialized) {
        return;
    }
    initialized = true;
    errdefer initialized = false;

    _allocator = allocator;
    _stdout = stdout;
    _null_fg_color = null_fg_color;
    _null_bg_color = null_bg_color;

    if (os_tag == .windows) {
        const signal = struct {
            extern "c" fn signal(
                sig: c_int,
                func: *const fn (c_int, c_int) callconv(windows.WINAPI) void,
            ) callconv(.C) *anyopaque;
        }.signal;
        _ = signal(SIG.INT, handleExitWindows);
    } else {
        const action = linux.Sigaction{
            .handler = .{ .handler = handleExit },
            .mask = linux.empty_sigset,
            .flags = 0,
        };
        _ = linux.sigaction(SIG.INT, &action, null);
    }

    if (os_tag == .windows) {
        const CP_UTF8 = 65001;
        const result = kernel32.SetConsoleOutputCP(CP_UTF8);
        if (result == windows.FALSE) {
            return InitError.FailedToSetConsoleOutputCP;
        }

        const setConsoleMode = struct {
            extern "kernel32" fn SetConsoleMode(
                console: windows.HANDLE,
                mode: windows.DWORD,
            ) callconv(windows.WINAPI) windows.BOOL;
        }.SetConsoleMode;

        const ENABLE_PROCESSED_OUTPUT = 0x1;
        const ENABLE_WRAP_AT_EOL_OUTPUT = 0x2;
        const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x4;
        const ENABLE_LVB_GRID_WORLDWIDE = 0x10;
        const result2 = setConsoleMode(
            _stdout.handle,
            ENABLE_PROCESSED_OUTPUT |
                ENABLE_WRAP_AT_EOL_OUTPUT |
                ENABLE_VIRTUAL_TERMINAL_PROCESSING |
                ENABLE_LVB_GRID_WORLDWIDE,
        );
        if (result2 == windows.FALSE) {
            return InitError.FailedToSetConsoleMode;
        }
    }

    // Use a guess if we can't get the terminal size
    terminal_size = terminalSize() orelse Size{ .width = 120, .height = 30 };
    draw_buffer = ByteList{};

    last_frame = try Frame.init(allocator, width, height);
    current_frame = try Frame.init(allocator, width, height);

    useAlternateBuffer();
    hideCursor(_stdout.writer()) catch {};

    should_redraw = true;
}

pub fn deinit() void {
    if (!initialized) {
        return;
    }
    initialized = false;

    useMainBuffer();
    showCursor(_stdout.writer()) catch {};

    draw_buffer.deinit(_allocator);
    last_frame.deinit(_allocator);
    current_frame.deinit(_allocator);
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

/// The actual size of the terminal window in characters. If the terminal size
/// cannot be determined, `null` is returned.
pub fn terminalSize() ?Size {
    if (os_tag == .windows) {
        return terminalSizeWindows();
    }

    var size: linux.winsize = undefined;
    const result = linux.ioctl(
        std.os.linux.STDOUT_FILENO,
        linux.T.IOCGWINSZ,
        @intFromPtr(&size),
    );
    if (result == 0) {
        return null;
    }

    return Size{
        .width = size.ws_col,
        .height = size.ws_row,
    };
}

fn terminalSizeWindows() ?Size {
    var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    const result = kernel32.GetConsoleScreenBufferInfo(_stdout.handle, &info);
    if (result == windows.FALSE) {
        return null;
    }

    return Size{
        .width = @bitCast(info.dwSize.X),
        .height = @bitCast(info.dwSize.Y),
    };
}

// TODO
pub fn setTerminalSize(width: u16, height: u16) void {
    should_redraw = true;

    if (.os_tag == .windows) {
        setTerminalSizeWindows(width, height);
    }

    // TODO: Implement for other platforms
    @compileError("setTerminalSize not implemented for this platform.");
}

// TODO
fn setTerminalSizeWindows(width: u16, height: u16) void {
    _ = height;
    _ = width;
}

/// The size of the imaginary canvas used for rendering. If larger than the
/// terminal size, part of the canvas will be clipped. If smaller, the canvas
/// will be centered in the terminal window.
pub fn canvasSize() Size {
    return current_frame.size;
}

/// Sets the size of the canvas. The old canvas is cropped to fit the new size.
/// Any new pixels are set to a default value.
pub fn setCanvasSize(width: u16, height: u16) !void {
    if (!initialized) {
        return;
    }

    should_redraw = true;

    last_frame.deinit(_allocator);
    var old_current = current_frame;
    defer old_current.deinit(_allocator);

    last_frame = try Frame.init(_allocator, width, height);
    current_frame = try Frame.init(_allocator, width, height);
    current_frame.copy(old_current);
}

/// Returns a view that covers the entire canvas.
pub fn view() View {
    return View{
        .left = 0,
        .top = 0,
        .width = current_frame.size.width,
        .height = current_frame.size.height,
    };
}

/// Sets the title of the terminal window. Fails silently if the terminal does
/// not support setting the title.
pub fn setTitle(title: []const u8) void {
    _stdout.writeAll(OSC ++ "0;") catch {};
    _stdout.writeAll(title) catch {};
    _stdout.writeAll(ST) catch {};
}

fn useAlternateBuffer() void {
    _stdout.writeAll(CSI ++ "?1049h") catch {};
}

fn useMainBuffer() void {
    _stdout.writeAll(CSI ++ "?1049l") catch {};
}

/// Overwrites the pixel at the given coordinates with the given values. Fails
/// silently if the canvas is not initialized or the coordinates are out of
/// bounds.
pub fn setPixel(x: u16, y: u16, fg: ?Color, bg: ?Color, char: u21) void {
    if (!initialized or !current_frame.inBounds(x, y)) {
        return;
    }

    current_frame.set(x, y, .{
        .fg = fg,
        .bg = bg,
        .char = char,
    });
}

/// Draws a pixel to the canvas. `null` values are treated as transperant. If
/// `fg` or `bg` is `null`, the corresponding foreground or background color is
/// not changed. if `fg` is `null`, `char` is not drawn. Fails silently if the
/// canvas is not initialized or the coordinates are out of bounds.
pub fn drawPixel(x: u16, y: u16, fg: ?Color, bg: ?Color, char: u21) void {
    if (!initialized or !current_frame.inBounds(x, y)) {
        return;
    }

    const old = current_frame.get(x, y);
    current_frame.set(x, y, .{
        .fg = fg orelse old.fg,
        .bg = bg orelse old.bg,
        .char = if (fg) |_| char else old.char,
    });
}

/// Renders the current frame to the terminal and advances the frame buffer,
/// providing an empty frame for the next draw.
pub fn render() !void {
    if (!initialized) {
        return error.NotInitialized;
    }
    defer should_redraw = false;

    updateTerminalSize();

    const draw_size = current_frame.size.bound(terminal_size);
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

    var last_fg, var last_bg = blk: {
        const p = current_frame.get(last_x, last_y).resolve();
        break :blk .{ p.fg, p.bg };
    };
    try setColor(writer, last_fg, last_bg);

    var diff_exists = false;
    var y: u16 = 0;
    while (y < draw_size.height) : (y += 1) {
        var x: u16 = 0;
        while (x < draw_size.width) : (x += 1) {
            const p = current_frame.get(x, y).resolve();
            if (!should_redraw and eql(p, last_frame.get(x, y).resolve())) {
                continue;
            }
            diff_exists = true;

            if (x != last_x or y != last_y) {
                try setCursorPos(writer, x + x_offset, y + y_offset);
            }
            last_x = x + 1; // Add 1 to account for cursor movement
            last_y = y;

            if ((p.fg != last_fg and p.bg != last_bg) or
                p.fg == null or
                p.bg == null)
            {
                try setColor(writer, p.fg, p.bg);
            } else if (p.fg != last_fg) {
                try setForeColor(writer, p.fg.?);
            } else if (p.bg != last_bg) {
                try setBackColor(writer, p.bg.?);
            }
            last_fg = p.fg;
            last_bg = p.bg;

            var utf8_bytes: [4]u8 = undefined;
            const len = try unicode.utf8Encode(p.char, &utf8_bytes);
            try writer.writeAll(utf8_bytes[0..len]);
        }
    }

    // Reset colors at the end so that the area outside the canvas is unaffected
    try resetColors(writer);
    if (diff_exists) {
        _stdout.writeAll(draw_buffer.items[0..draw_buffer.items.len]) catch {};
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
    std.mem.swap(Frame, &last_frame, &current_frame);
    current_frame.fill(.{ .fg = null, .bg = null, .char = ' ' });

    // Limit the size of the draw buffer to not waste memory
    const max_size = current_frame.size.area() * 12;
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

fn setColor(writer: anytype, fg: ?Color, bg: ?Color) !void {
    if (fg == null or bg == null) {
        try resetColors(writer);
        if (fg) |fg_color| {
            try setForeColor(writer, fg_color);
        }
        if (bg) |bg_color| {
            try setBackColor(writer, bg_color);
        }
        return;
    }
    // If both colors are non-null, write with single escape sequence to save bytes
    try writer.print(CSI ++ "38;5;{};48;5;{}m", .{ fg.?, bg.? });
}

fn setForeColor(writer: anytype, fg: Color) !void {
    try writer.print(CSI ++ "38;5;{}m", .{fg});
}

fn setBackColor(writer: anytype, bg: Color) !void {
    try writer.print(CSI ++ "48;5;{}m", .{bg});
}

fn resetCursor(writer: anytype) !void {
    try writer.writeAll(CSI ++ "H");
}

fn setCursorPos(writer: anytype, x: u16, y: u16) !void {
    // Convert 0-based coordinates to 1-based
    try writer.print(CSI ++ "{};{}H", .{ y + 1, x + 1 });
}

fn showCursor(writer: anytype) !void {
    try writer.writeAll(CSI ++ "?25h");
}

fn hideCursor(writer: anytype) !void {
    try writer.writeAll(CSI ++ "?25l");
}
