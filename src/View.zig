const std = @import("std");
const assert = std.debug.assert;
const unicode = std.unicode;

const root = @import("root.zig");
const Color = root.Color;

const Self = @This();

const WriterContext = struct {
    self: Self,
    start: usize = 0,
    x: u16,
    y: u16,
    fg: ?Color,
    bg: ?Color,
};
const Writer = std.io.Writer(*WriterContext, error{}, writeFn);

pub const Alignment = enum {
    left,
    center,
    right,
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
    fg: ?Color,
    bg: ?Color,
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
    fg: ?Color,
    bg: ?Color,
    text: []const u8,
) u16 {
    var code_points = (unicode.Utf8View.init(text) catch unreachable).iterator();
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
    fg: ?Color,
    bg: ?Color,
    text: []const u8,
) void {
    const len = unicode.utf8CountCodepoints(text) catch unreachable;
    var x, const start = allignText(alignment, self.width, len);

    var codepoints = (unicode.Utf8View.init(text) catch unreachable).iterator();
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
    fg: ?Color,
    bg: ?Color,
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
    fg: ?Color,
    bg: ?Color,
    comptime format: []const u8,
    args: anytype,
) void {
    // We don't need to know the length for left alignment
    if (alignment == .left) {
        self.printAt(0, y, fg, bg, format, args);
        return;
    }

    // Get length of formatted string
    const len = getFmtLen(format, args);
    const x, const start = allignText(alignment, self.width, len);

    var context = WriterContext{
        .self = self,
        .start = start,
        .x = x,
        .y = y,
        .fg = fg,
        .bg = bg,
    };
    const writer = Writer{ .context = &context };
    writer.print(format, args) catch unreachable;
}

fn allignText(alignment: Alignment, view_width: u16, text_len: usize) struct { u16, usize } {
    const x: u16 = if (text_len <= view_width) switch (alignment) {
        .left => 0,
        .center => @intCast((view_width - text_len) / 2),
        .right => @intCast(view_width - text_len),
    } else 0;
    const start = if (text_len <= view_width) 0 else switch (alignment) {
        .left => 0,
        .center => (text_len - view_width) / 2,
        .right => text_len - view_width,
    };

    return .{ x, start };
}

fn writeFn(context: *WriterContext, bytes: []const u8) !usize {
    var codepoints = (unicode.Utf8View.init(bytes) catch unreachable).iterator();
    var bytes_start: usize = 0;
    while (context.start > 0) : (context.start -= 1) {
        if (codepoints.nextCodepoint()) |c| {
            bytes_start += unicode.utf8CodepointSequenceLength(c) catch unreachable;
        } else {
            return bytes.len;
        }
    }

    if (context.x < context.self.width) {
        _ = context.self.writeText(context.x, context.y, context.fg, context.bg, bytes[bytes_start..]);
        context.x +|= @intCast(@min(std.math.maxInt(u16), bytes.len));
    }

    // Bytes that were truncated are also considered written
    return bytes.len;
}

// Gets the length of a formatted string.
fn getFmtLen(comptime format: []const u8, args: anytype) usize {
    var len: usize = 0;
    const writer = std.io.Writer(*usize, error{}, getFmtLenWriterFn){ .context = &len };
    std.fmt.format(writer, format, args) catch unreachable;
    return len;
}

fn getFmtLenWriterFn(context: *usize, bytes: []const u8) !usize {
    context.* += unicode.utf8CountCodepoints(bytes) catch unreachable;
    return bytes.len;
}

/// Draws a box positioned relative to the view.
pub fn drawBox(
    self: Self,
    left: u16,
    top: u16,
    width: u16,
    height: u16,
    fg: ?Color,
    bg: ?Color,
) void {
    if (width == 0 or height == 0) {
        return;
    }

    if (width == 1 and height == 1) {
        _ = self.writePixel(left, top, fg, bg, '☐');
        return;
    }

    const right = left + width - 1;
    const bottom = top + height - 1;

    if (width == 1) {
        for (top..bottom + 1) |y| {
            _ = self.writePixel(left, @intCast(y), fg, bg, '║');
        }
        return;
    }
    if (height == 1) {
        for (left..right + 1) |x| {
            _ = self.writePixel(@intCast(x), top, fg, bg, '═');
        }
        return;
    }

    _ = self.writePixel(left, top, fg, bg, '╔');
    for (left + 1..right) |x| {
        _ = self.writePixel(@intCast(x), top, fg, bg, '═');
    }
    _ = self.writePixel(right, top, fg, bg, '╗');

    for (top + 1..bottom) |y| {
        _ = self.writePixel(left, @intCast(y), fg, bg, '║');
        _ = self.writePixel(right, @intCast(y), fg, bg, '║');
    }

    _ = self.writePixel(left, bottom, fg, bg, '╚');
    for (left + 1..right) |x| {
        _ = self.writePixel(@intCast(x), bottom, fg, bg, '═');
    }
    _ = self.writePixel(right, bottom, fg, bg, '╝');
}
