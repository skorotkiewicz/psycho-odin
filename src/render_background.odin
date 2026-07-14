package main

import "core:math"
import rl "vendor:raylib"

Background_Response :: struct {
	bass_glow, ribbon_amplitude, sparkle, beat_flash, drift: f32,
}

background_response :: proc(bass, mid, high, onset, pace, pulse: f32) -> Background_Response {
	b := clamp(bass, 0, 1)
	m := clamp(mid, 0, 1)
	h := clamp(high, 0, 1)
	o := clamp(onset, 0, 1)
	p := clamp(pace, 0, 1)
	return {
		bass_glow = clamp(b * 0.78 + o * 0.30 + pulse * 0.22, 0, 1),
		ribbon_amplitude = clamp(m * 0.76 + b * 0.18 + o * 0.16, 0, 1),
		sparkle = clamp(h * 0.82 + o * 0.28, 0, 1),
		beat_flash = clamp(o * 0.82 + pulse * 0.48, 0, 1),
		drift = 0.28 + p * 1.72,
	}
}

draw_music_background :: proc(
	width, height: i32,
	music_time, bass, mid, high, onset, pace, pulse, visual_strength: f32,
) {
	if width <= 0 || height <= 0 do return
	p := clamp(pace, 0, 1)
	pace_curve := p * p * (3 - 2 * p)
	strength := 0.38 + clamp(visual_strength, 0, 1) * 0.62
	response := background_response(bass, mid, high, onset, p, pulse)
	bg_top := pace_color(p, 0.08 + pace_curve * 0.13)
	bg_bottom := pace_color(max(0, p - 0.22), 0.014 + pace_curve * 0.036)
	rl.DrawRectangleGradientV(0, 0, width, height, bg_top, bg_bottom)

	center := rl.Vector2{f32(width) * 0.5, f32(height) * 0.52}
	scene_radius := f32(min(width, height))
	rl.BeginBlendMode(.ADDITIVE)

	// Bass creates a soft neon core behind the road and expands the concentric tunnel.
	glow_radius := scene_radius * (0.075 + response.bass_glow * 0.095)
	glow_alpha := u8(clamp((18 + response.bass_glow * 62) * strength, 0, 255))
	glow_inner := pace_color(max(0, p - 0.10), 0.52 + response.bass_glow * 0.30, glow_alpha)
	glow_outer := pace_color(p, 0.12, 0)
	rl.DrawCircleGradient(center, glow_radius, glow_inner, glow_outer)
	for ring in 0 ..< 6 {
		ring_f := f32(ring)
		radius :=
			scene_radius * (0.11 + ring_f * 0.115) +
			response.beat_flash * (18 + ring_f * 7) +
			pace_curve * ring_f * 10
		alpha := u8(clamp((28 + ring_f * 7 + response.bass_glow * 24) * strength, 0, 145))
		ring_color := pace_color(p + ring_f * 0.018, 0.40 + ring_f * 0.07, alpha)
		rl.DrawCircleLinesV(center, radius, ring_color)
	}

	// Onsets briefly reveal radial rays without producing a full-screen white flash.
	if response.beat_flash > 0.02 {
		for ray in 0 ..< 14 {
			ray_f := f32(ray)
			angle := f64(ray_f / 14 * 2 * f32(math.PI) + music_time * (0.025 + p * 0.055))
			inner_radius := scene_radius * (0.11 + response.bass_glow * 0.025)
			outer_radius := inner_radius + scene_radius * (0.18 + response.beat_flash * 0.20)
			start := rl.Vector2 {
				center.x + f32(math.cos(angle)) * inner_radius,
				center.y + f32(math.sin(angle)) * inner_radius,
			}
			finish := rl.Vector2 {
				center.x + f32(math.cos(angle)) * outer_radius,
				center.y + f32(math.sin(angle)) * outer_radius,
			}
			alpha := u8(clamp(response.beat_flash * 42 * strength, 0, 70))
			rl.DrawLineEx(start, finish, 0.7 + response.beat_flash, pace_color(p, 0.72, alpha))
		}
	}

	// Mid frequencies bend broad waveform ribbons; highs add a finer harmonic ripple.
	segment_count := max(32, min(96, int(width) / 22))
	for layer in 0 ..< 3 {
		layer_f := f32(layer)
		direction: f32 = 1
		if layer % 2 == 1 do direction = -1
		base_y := f32(height) * (0.28 + layer_f * 0.16)
		amplitude :=
			f32(height) * (0.014 + response.ribbon_amplitude * 0.052) * (1 - layer_f * 0.12)
		frequency := 1.6 + layer_f * 0.72 + p * 1.25
		phase := music_time * response.drift * direction + layer_f * 1.85
		previous: rl.Vector2
		for segment in 0 ..= segment_count {
			u := f32(segment) / f32(segment_count)
			primary := f32(math.sin(f64(u * 2 * f32(math.PI) * frequency + phase)))
			harmonic := f32(math.sin(f64(u * 2 * f32(math.PI) * (frequency * 2.4) - phase * 1.35)))
			y :=
				base_y +
				primary * amplitude +
				harmonic * amplitude * (0.10 + response.sparkle * 0.22)
			point := rl.Vector2{u * f32(width), y}
			if segment > 0 {
				alpha := u8(
					clamp(
						(32 +
							response.ribbon_amplitude * 42 +
							response.beat_flash * 20 -
							layer_f * 5) *
						strength,
						0,
						125,
					),
				)
				color := pace_color(p + layer_f * 0.07, 0.54 + response.sparkle * 0.24, alpha)
				rl.DrawLineEx(previous, point, 0.8 + response.bass_glow * 1.3, color)
			}
			previous = point
		}
	}

	// Deterministic stars avoid stored assets and remain stable between frames.
	for star in 0 ..< 48 {
		star_f := f32(star)
		x_seed := f32((star * 73 + 19) % 997) / 997
		y_seed := f32((star * 151 + 47) % 991) / 991
		drift_x :=
			f32(math.sin(f64(music_time * response.drift * 0.11 + star_f * 1.73))) *
			f32(width) *
			0.018
		twinkle :=
			0.5 +
			0.5 * f32(math.sin(f64(music_time * (1.4 + response.sparkle * 5.5) + star_f * 2.17)))
		intensity := clamp(response.sparkle * 0.72 + twinkle * 0.42, 0, 1)
		alpha := u8(clamp((8 + intensity * 95) * strength, 0, 125))
		radius := 0.45 + intensity * 1.45
		star_color := pace_color(p + y_seed * 0.14, 0.60 + intensity * 0.32, alpha)
		rl.DrawCircleV({x_seed * f32(width) + drift_x, y_seed * f32(height)}, radius, star_color)
	}
	rl.EndBlendMode()
}
