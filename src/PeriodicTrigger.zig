//! A trigger that fires at a fixed period, meant for use in single-threaded
//! event loops.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

/// The Io instance to get timestamps from.
io: Io,
/// The fixed period.
period: Io.Duration,
/// Whether to skip missed periods. If true, the trigger will skip to the most
/// recent complete period when `trigger` is called.
skip_missed: bool,
/// The timestamp of the last trigger firing.
last: Io.Timestamp,

/// Initializes a new `PeriodicTrigger`.
///
/// `io` - The Io instance to get timestamps from.
///
/// `period` - is the fixed period.
///
/// `skip_missed` - If true, the trigger will skip to the most recent complete
/// period when `trigger` is called.
pub fn init(io: Io, period: Io.Duration, skip_missed: bool) @This() {
    assert(period.nanoseconds > 0);
    return .{
        .io = io,
        .period = period,
        .skip_missed = skip_missed,
        .last = .now(io, .real),
    };
}

/// Checks if the trigger should fire. If it should not fire yet, returns
/// `null`. If it should fire, returns the duration between the last and
/// current trigger firings (i.e., `period`). If `skip_missed` is true, the
/// trigger will return a multiple of `period`.
pub fn trigger(self: *@This()) ?Io.Duration {
    const now: Io.Timestamp = .now(self.io, .real);
    // No time has passed yet
    if (now.nanoseconds <= self.last.nanoseconds) {
        return null;
    }

    const elapsed = self.last.durationTo(now);
    if (elapsed.nanoseconds < self.period.nanoseconds) {
        return null;
    }

    if (self.skip_missed) {
        const partial_period_time = @rem(elapsed.nanoseconds, self.period.nanoseconds);
        const time_to_add = elapsed.nanoseconds - partial_period_time;
        self.last = self.last.addDuration(.fromNanoseconds(time_to_add));
        return .fromNanoseconds(time_to_add);
    } else {
        self.last = self.last.addDuration(self.period);
        return self.period;
    }
}
