// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Window ids. Every gtty window (job windows now; peeks and modals
//! later) gets a unique 32-bit id, shown as 8 hex
//! digits. Job windows also get a serial number (#1, #2, …): that one is
//! the label the user sees; the id is for the code.
//!
//! Ids come from a Weyl sequence: a random start plus n × an odd constant,
//! mod 2^32. That never repeats within 2^32 ids and doesn't look sequential.

const std = @import("std");

pub const Id = u32;

const step: u32 = 0x9E3779B9; // odd (2^32 / golden ratio)

pub const Gen = struct {
    next: u32,

    pub fn init(seed: u32) Gen {
        return .{ .next = seed };
    }

    pub fn take(g: *Gen) Id {
        const id = g.next;
        g.next +%= step;
        return id;
    }
};

/// "1a2b3c4d"
pub fn hex(id: Id, buf: *[8]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>8}", .{id}) catch unreachable;
}

test "ids are unique and print as 8 hex digits" {
    const t = std.testing;
    var g = Gen.init(0xfffffffe);
    var seen: std.AutoHashMapUnmanaged(Id, void) = .empty;
    defer seen.deinit(t.allocator);
    for (0..10_000) |_| {
        const r = try seen.getOrPut(t.allocator, g.take());
        try t.expect(!r.found_existing);
    }
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("0000002a", hex(42, &buf));
    try t.expectEqualStrings("deadbeef", hex(0xdeadbeef, &buf));
}
