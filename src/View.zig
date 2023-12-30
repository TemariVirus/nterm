const std = @import("std");
const root = @import("root.zig");
const Utf8View = std.unicode.Utf8View;
const Color = root.Color;
const assert = std.debug.assert;

const Self = @This();

const WriterContext = struct {
    self: Self,
    x: u16,
    y: u16,
    fg: Color,
    bg: Color,
};
const Writer = std.io.Writer(*WriterContext, error{}, writeFn);

pub const Alignment = enum {
    Left,
    Center,
    Right,
};

left: u16,
top: u16,
width: u16,
height: u16,

pub fn init(left: u16, top: u16, width: u16, height: u16) Self {
    const canvas_size = root.canvasSize();
    assert(left + width <= canvas_size.width and
        top + height <= canvas_size.height);

    return Self{
        .left = left,
        .top = top,
        .width = width,
        .height = height,
    };
}

pub fn sub(self: Self, left: u16, top: u16, width: u16, height: u16) Self {
    assert(left + width <= self.width and top + height <= self.height);

    const new_left = self.left + left;
    const new_top = self.top + top;
    return Self{
        .left = new_left,
        .top = new_top,
        .width = width,
        .height = height,
    };
}

pub fn writePixel(
    self: Self,
    x: u16,
    y: u16,
    fg: Color,
    bg: Color,
    char: u21,
) void {
    assert(x < self.width and y < self.height);
    root.drawPixel(x + self.left, y + self.top, fg, bg, char);
}

/// Overflows are truncated.
pub fn writeText(
    self: Self,
    x: u16,
    y: u16,
    fg: Color,
    bg: Color,
    text: []const u8,
) void {
    var code_points = (Utf8View.init(text) catch unreachable).iterator();
    var i = x;
    while (code_points.nextCodepoint()) |c| {
        if (i >= self.width) {
            break;
        }
        self.writePixel(i, y, fg, bg, c);
        i += 1;
    }
}

/// Overflows are truncated.
pub fn writeAligned(
    self: Self,
    alignment: Alignment,
    y: u16,
    fg: Color,
    bg: Color,
    text: []const u8,
) void {
    const len = std.unicode.utf8CountCodepoints(text) catch unreachable;
    var x: u16 = if (len <= self.width) switch (alignment) {
        .Left => 0,
        .Center => @intCast((self.width - len) / 2),
        .Right => @intCast(self.width - len),
    } else 0;
    const start = if (len <= self.width) 0 else switch (alignment) {
        .Left => 0,
        .Center => (len - self.width) / 2,
        .Right => len - self.width,
    };

    var codepoints = (Utf8View.init(text) catch unreachable).iterator();
    for (0..start) |_| {
        _ = codepoints.nextCodepoint();
    }
    while (codepoints.nextCodepoint()) |c| {
        if (x >= self.width) {
            break;
        }
        self.writePixel(x, y, fg, bg, c);
        x += 1;
    }
}

/// Overflows are truncated.
pub fn printAt(
    self: Self,
    x: u16,
    y: u16,
    fg: Color,
    bg: Color,
    comptime format: []const u8,
    args: anytype,
) !void {
    var context = WriterContext{
        .self = self,
        .x = x,
        .y = y,
        .fg = fg,
        .bg = bg,
    };
    const writer = Writer{ .context = &context };
    try writer.print(format, args);
}

/// Overflows are truncated.
pub fn printAligned(
    self: Self,
    alignment: Alignment,
    y: u16,
    fg: Color,
    bg: Color,
    comptime format: []const u8,
    args: anytype,
) !void {
    if (alignment == .Left) {
        try self.printAt(0, y, fg, bg, format, args);
        return;
    }

    var buf = std.ArrayList(u8).init(root._allocator);
    defer buf.deinit();

    try buf.writer().print(format, args);

    if (buf.items.len > self.width) {
        const start = switch (alignment) {
            .Left => unreachable,
            .Center => (buf.items.len - self.width) / 2,
            .Right => buf.items.len - self.width,
        };
        self.writeText(0, y, fg, bg, buf.items[start..]);
        return;
    }

    const x = switch (alignment) {
        .Left => unreachable,
        .Center => (self.width - buf.items.len) / 2,
        .Right => self.width - buf.items.len,
    };
    self.writeText(@intCast(x), y, fg, bg, buf.items);
}

fn writeFn(context: *WriterContext, bytes: []const u8) !usize {
    if (context.x < context.self.width) {
        context.self.writeText(context.x, context.y, context.fg, context.bg, bytes);
        context.x += @as(u16, @intCast(bytes.len));
    }

    // Bytes that were truncated are also considered written
    return bytes.len;
}

pub fn drawBox(self: Self, left: u16, top: u16, width: u16, height: u16) void {
    if (width == 0 or height == 0) {
        return;
    }

    if (width == 1 and height == 1) {
        self.writePixel(left, top, .White, .Black, '☐');
        return;
    }

    const right = left + width - 1;
    const bottom = top + height - 1;

    if (width == 1) {
        for (top..bottom + 1) |y| {
            self.writePixel(left, @intCast(y), .White, .Black, '║');
        }
        return;
    }
    if (height == 1) {
        for (left..right + 1) |x| {
            self.writePixel(@intCast(x), top, .White, .Black, '═');
        }
        return;
    }

    self.writePixel(left, top, .White, .Black, '╔');
    for (left + 1..right) |x| {
        self.writePixel(@intCast(x), top, .White, .Black, '═');
    }
    self.writePixel(right, top, .White, .Black, '╗');

    for (top + 1..bottom) |y| {
        self.writePixel(left, @intCast(y), .White, .Black, '║');
        self.writePixel(right, @intCast(y), .White, .Black, '║');
    }

    self.writePixel(left, bottom, .White, .Black, '╚');
    for (left + 1..right) |x| {
        self.writePixel(@intCast(x), bottom, .White, .Black, '═');
    }
    self.writePixel(right, bottom, .White, .Black, '╝');
}
