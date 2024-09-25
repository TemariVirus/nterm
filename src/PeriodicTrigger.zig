//! A trigger that fires at a fixed period, meant for use in single-threaded
//! event loops.

const std = @import("std");
const assert = std.debug.assert;
const nanoTimestamp = std.time.nanoTimestamp;

/// The fixed period, in nanoseconds.
period: u64,
/// Whether to skip missed periods. If true, the trigger will skip to the most
/// recent complete period when `trigger` is called.
skip_missed: bool,
/// The timestamp of the last trigger firing, in nanoseconds.
last: i128,

/// Initializes a new `PeriodicTrigger`.
///
/// `period` - is the fixed period, in nanoseconds.
///
/// `skip_missed` - If true, the trigger will skip to the most recent complete
/// period when `trigger` is called.
pub fn init(period: u64, skip_missed: bool) @This() {
    assert(period > 0);
    return .{
        .period = period,
        .skip_missed = skip_missed,
        .last = nanoTimestamp(),
    };
}

/// Checks if the trigger should fire. If it should not fire yet, returns
/// `null`. If it should fire, returns the nanoseconds between the last and
/// current trigger firings (i.e., `period`). If `skip_missed` is true, the
/// trigger will return a multiple of `period` instead.
pub fn trigger(self: *@This()) ?u64 {
    const now = nanoTimestamp();
    // No time has passed yet
    if (now <= self.last) {
        return null;
    }

    const elapsed: u128 = @intCast(now - self.last);
    if (elapsed < self.period) {
        return null;
    }

    if (self.skip_missed) {
        const partial_period_time = elapsed % self.period;
        const time_to_add: u64 = @intCast(elapsed - partial_period_time);
        self.last += time_to_add;
        return time_to_add;
    } else {
        self.last += self.period;
        return self.period;
    }
}
