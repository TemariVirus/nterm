const std = @import("std");
const assert = std.debug.assert;

const root = @import("root.zig");
const Frame = root.Frame;
const View = root.View;

time: u64 = 0,
frames: []const Frame,
/// The time at which each frame ends, in nanoseconds.
frame_times: []const u64,
view: View,

const Self = @This();

pub fn init(frames: []const Frame, frame_times: []const u64, view: View) Self {
    assert(frames.len > 0);
    assert(frames.len == frame_times.len);

    return .{
        .frames = frames,
        .frame_times = frame_times,
        .view = view,
    };
}

pub fn done(self: Self) bool {
    return self.time >= self.frame_times[self.frame_times.len - 1];
}

/// Returns true if the animation is done.
pub fn tick(self: *Self, nanoseconds: u64) bool {
    self.time +|= nanoseconds;
    return self.forceRender();
}

/// Returns true if the animation is done.
pub fn forceRender(self: Self) bool {
    if (self.done()) {
        return true;
    }

    // Binary search
    var left: usize = 0;
    var right: usize = self.frame_times.len;
    while (left < right) {
        const mid = (left + right) / 2;
        if (self.frame_times[mid] <= self.time) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    const frame = self.frames[left];
    for (0..frame.size.height) |y| {
        for (0..frame.size.width) |x| {
            const pixel = frame.get(@intCast(x), @intCast(y));
            _ = self.view.writePixel(@intCast(x), @intCast(y), pixel.fg, pixel.bg, pixel.char);
        }
    }

    return false;
}
