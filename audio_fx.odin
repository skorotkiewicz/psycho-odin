package main

import "core:math"

// Audio-thread state. The effect is optional because binaural/ASMR responses vary by listener.
fx_on: bool
fx_amount: f32 = 0.22
fx_beat_hz: f64 = 7
fx_tingle: f32
fx_rate: f64 = 48000
fx_channels: int = 2
fx_phase_l, fx_phase_r, fx_pan_phase: f64
fx_noise: u32 = 0x91e10da5
fx_soft_noise: f32
fx_delay: [4096][2]f32
fx_delay_at: int

audio_fx :: proc "c" (buffer_data: rawptr, frames: u32) {
	if !fx_on || fx_channels < 2 do return
	samples := cast([^]f32)buffer_data
	tau := 2.0 * math.PI
	for frame in 0 ..< int(frames) {
		fx_phase_l += tau * 180.0 / fx_rate
		fx_phase_r += tau * (180.0 + fx_beat_hz) / fx_rate
		fx_pan_phase += tau * 0.13 / fx_rate
		if fx_phase_l > tau do fx_phase_l -= tau
		if fx_phase_r > tau do fx_phase_r -= tau
		if fx_pan_phase > tau do fx_pan_phase -= tau

		fx_noise ~= fx_noise << 13
		fx_noise ~= fx_noise >> 17
		fx_noise ~= fx_noise << 5
		white := f32(fx_noise & 0xffff) / 32767.5 - 1.0
		fx_soft_noise += (white - fx_soft_noise) * 0.035
		breath := fx_soft_noise * (0.002 + fx_tingle * 0.004)
		pan := f32(math.sin(fx_pan_phase))
		tone := fx_amount * 0.025
		dry_l := samples[frame * fx_channels]
		dry_r := samples[frame * fx_channels + 1]
		delayed := (fx_delay_at + len(fx_delay) - 840) % len(fx_delay)
		width := fx_amount * 0.055
		left :=
			dry_l +
			f32(math.sin(fx_phase_l)) * tone +
			breath * (1 - pan) +
			fx_delay[delayed][1] * width
		right :=
			dry_r +
			f32(math.sin(fx_phase_r)) * tone +
			breath * (1 + pan) +
			fx_delay[delayed][0] * width
		fx_delay[fx_delay_at] = {dry_l, dry_r}
		fx_delay_at = (fx_delay_at + 1) % len(fx_delay)
		samples[frame * fx_channels] = clamp(left, -1, 1)
		samples[frame * fx_channels + 1] = clamp(right, -1, 1)
	}
}
