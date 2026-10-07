// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The error beep: the system alert sound where there is one (macOS), or a
//! short soft tone played through SDL audio.

const std = @import("std");
const c = @import("../c.zig").c;

var stream: ?*c.SDL_AudioStream = null;

pub fn beep() void {
    if (c.gtty_beep() != 0) return;
    tone();
}

fn tone() void {
    const rate = 44100;
    if (stream == null) {
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) return;
        const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = 1, .freq = rate };
        stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);
        const s = stream orelse return;
        _ = c.SDL_ResumeAudioStreamDevice(s);
    }
    // 120 ms at 660 Hz with a quick fade in/out, so it doesn't click.
    var samples: [rate * 120 / 1000]f32 = undefined;
    for (&samples, 0..) |*v, i| {
        const t = @as(f32, @floatFromInt(i)) / rate;
        const n: f32 = @floatFromInt(samples.len);
        const fi: f32 = @floatFromInt(i);
        const env = @min(@min(fi / 400, (n - fi) / 1500), 1);
        v.* = 0.25 * env * @sin(2 * std.math.pi * 660 * t);
    }
    _ = c.SDL_PutAudioStreamData(stream.?, &samples, @intCast(samples.len * @sizeOf(f32)));
}
