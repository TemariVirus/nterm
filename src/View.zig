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

left: u16 = 0,
top: u16 = 0,
width: u16,
height: u16,

/// Creates a new view based on the position of this view.
pub fn sub(self: Self, left: u16, top: u16, width: u16, height: u16) Self {
    const new_left = self.left + left;
    const new_top = self.top + top;
    return Self{
        .left = new_left,
        .top = new_top,
        .width = width,
        .height = height,
    };
}

/// Writes a pixel to the screen if the pixel is within the bounds of the view.
/// Returns `true` if the pixel was written; Otherwise, `false`.
pub fn writePixel(
    self: Self,
    x: u16,
    y: u16,
    fg: Color,
    bg: Color,
    char: u21,
) bool {
    if (x < self.width and y < self.height) {
        root.drawPixel(x + self.left, y + self.top, fg, bg, char);
        return true;
    }
    return false;
}

/// Overflows are truncated. Returns the number of characters written.
pub fn writeText(
    self: Self,
    x: u16,
    y: u16,
    fg: Color,
    bg: Color,
    text: []const u8,
) u16 {
    var code_points = (Utf8View.init(text) catch unreachable).iterator();
    var i = x;
    while (code_points.nextCodepoint()) |c| {
        if (!self.writePixel(i, y, fg, bg, c)) {
            break;
        }
        i += 1;
    }
    return i - x;
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
        _ = self.writePixel(x, y, fg, bg, c);
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
) void {
    var context = WriterContext{
        .self = self,
        .x = x,
        .y = y,
        .fg = fg,
        .bg = bg,
    };
    const writer = Writer{ .context = &context };
    writer.print(format, args) catch unreachable;
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
    // Avoid allcating if possible
    if (alignment == .Left) {
        self.printAt(0, y, fg, bg, format, args);
        return;
    }

    var buf = std.ArrayList(u8).init(root._allocator);
    defer buf.deinit();

    try buf.writer().print(format, args);
    self.writeAligned(alignment, y, fg, bg, buf.items);
}

fn writeFn(context: *WriterContext, bytes: []const u8) !usize {
    if (context.x < context.self.width) {
        _ = context.self.writeText(context.x, context.y, context.fg, context.bg, bytes);
        context.x +|= @intCast(@min(std.math.maxInt(u16), bytes.len));
    }

    // Bytes that were truncated are also considered written
    return bytes.len;
}

/// Draws a double-lined box along the edges of the view.
pub fn drawBox(self: Self, left: u16, top: u16, width: u16, height: u16) void {
    if (width == 0 or height == 0) {
        return;
    }

    if (width == 1 and height == 1) {
        _ = self.writePixel(left, top, .White, .Black, '☐');
        return;
    }

    const right = left + width - 1;
    const bottom = top + height - 1;

    if (width == 1) {
        for (top..bottom + 1) |y| {
            _ = self.writePixel(left, @intCast(y), .White, .Black, '║');
        }
        return;
    }
    if (height == 1) {
        for (left..right + 1) |x| {
            _ = self.writePixel(@intCast(x), top, .White, .Black, '═');
        }
        return;
    }

    _ = self.writePixel(left, top, .White, .Black, '╔');
    for (left + 1..right) |x| {
        _ = self.writePixel(@intCast(x), top, .White, .Black, '═');
    }
    _ = self.writePixel(right, top, .White, .Black, '╗');

    for (top + 1..bottom) |y| {
        _ = self.writePixel(left, @intCast(y), .White, .Black, '║');
        _ = self.writePixel(right, @intCast(y), .White, .Black, '║');
    }

    _ = self.writePixel(left, bottom, .White, .Black, '╚');
    for (left + 1..right) |x| {
        _ = self.writePixel(@intCast(x), bottom, .White, .Black, '═');
    }
    _ = self.writePixel(right, bottom, .White, .Black, '╝');
}
