const std = @import("std");
const unicode = @import("std").unicode;

pub fn utf8CountCodepoints(s: []const u8) usize {
    var len: usize = 0;

    const N = @sizeOf(usize);
    const MASK: usize = @bitCast(@as([@sizeOf(usize)]u8, @splat(0x80)));

    var i: usize = 0;
    while (i < s.len) {
        // Fast path for ASCII
        while (i + N <= s.len) : (i += N) {
            const v = std.mem.readInt(
                usize,
                s[i..][0..N],
                @import("builtin").cpu.arch.endian(),
            );
            if (v & MASK != 0) break;
            len += N;
        }

        if (i < s.len) {
            i += unicode.utf8ByteSequenceLength(s[i]) catch 1;
            len += 1;
        }
    }

    return len;
}

pub const Utf8Iterator = struct {
    bytes: []const u8,

    pub fn init(text: []const u8) Utf8Iterator {
        return .{ .bytes = text };
    }

    pub fn next(self: *Utf8Iterator) ?u21 {
        if (self.bytes.len == 0) {
            return null;
        }

        const len = unicode.utf8ByteSequenceLength(self.bytes[0]) catch {
            self.bytes = self.bytes[1..];
            return '�';
        };
        if (self.bytes.len < len) {
            self.bytes = &.{};
            return '�';
        }
        defer self.bytes = self.bytes[len..];
        return unicode.utf8Decode(self.bytes[0..len]) catch '�';
    }
};
