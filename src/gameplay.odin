package main

import "core:math"

steer_input :: proc(left, right: bool) -> f32 {
	direction: f32
	if left do direction += 1
	if right do direction -= 1
	return direction
}

mouse_lane_target :: proc(mouse_x, screen_width: i32) -> f32 {
	if screen_width <= 1 do return 0
	// The outer 8% on either side is already full lock, keeping steering reachable in a window.
	center := f32(screen_width) * 0.5
	half_control_width := f32(screen_width) * 0.42
	return clamp((center - f32(mouse_x)) / half_control_width, -1, 1)
}

smooth_mouse_lane :: proc(current, target, dt: f32, response_rate: f32 = 26) -> f32 {
	response := 1 - f32(math.exp(f64(-response_rate * max(0, dt))))
	return clamp(current + (target - current) * response, -1, 1)
}

ride_finished :: proc(paused, playback_seen, music_playing: bool) -> bool {
	return !paused && playback_seen && !music_playing
}

ride_controls_enabled :: proc(paused, finished: bool) -> bool {
	return !paused && !finished
}

Hud_Mode :: enum {
	FULL,
	HIDDEN,
	MAP_ONLY,
}

next_hud_mode :: proc(mode: Hud_Mode) -> Hud_Mode {
	switch mode {
	case .FULL:
		return .HIDDEN
	case .HIDDEN:
		return .MAP_ONLY
	case .MAP_ONLY:
		return .FULL
	}
	return .FULL
}

Overlay_Visibility :: struct {
	ride_hud, map_only, results: bool,
}

overlay_visibility :: proc(hud_mode: Hud_Mode, finished: bool) -> Overlay_Visibility {
	visibility := Overlay_Visibility {
		results = finished,
	}
	visibility.ride_hud = hud_mode == .FULL
	visibility.map_only = hud_mode == .MAP_ONLY
	return visibility
}

Hazard_Outcome :: struct {
	shield, score, streak, color_chain, crashes: int,
	last_tone:                                   i32,
	blocked:                                     bool,
}

resolve_hazard :: proc(
	shield, score, streak, color_chain: int,
	last_tone: i32,
	crashes: int,
	overdrive: f32,
) -> Hazard_Outcome {
	result := Hazard_Outcome {
		shield      = shield,
		score       = score,
		streak      = streak,
		color_chain = color_chain,
		last_tone   = last_tone,
		crashes     = crashes,
	}
	if overdrive > 0 {
		result.blocked = true
		return result
	}

	result.shield -= 1
	result.score = max(0, result.score - 350)
	result.streak, result.color_chain, result.last_tone = 0, 0, -1
	if result.shield <= 0 {
		result.crashes += 1
		result.shield = 3
		result.score /= 2
	}
	return result
}

lane_position :: proc(road_width, normalized_lane: f32) -> f32 {
	return normalized_lane * road_width * 2 / 3
}
