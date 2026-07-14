package main

import "core:math"
import rl "vendor:raylib"

LANE_COLLISION_TOLERANCE :: f32(0.43)

SECRET_OVERDRIVE_SECONDS :: f32(999)
SECRET_SEQUENCE_TIMEOUT :: f32(5)
SECRET_OVERDRIVE_SEQUENCE := [7]rl.KeyboardKey{.S, .T, .S, .G, .H, .O, .F10}

GHOST_PILOT_LOOKAHEAD :: 24
GHOST_PILOT_RESPONSE :: f32(8)

Secret_Sequence_State :: struct {
	matched:   int,
	remaining: f32,
}

Secret_Sequence_Step :: struct {
	state:     Secret_Sequence_State,
	activated: bool,
}

secret_overdrive_sequence_step :: proc(
	state: Secret_Sequence_State,
	key: rl.KeyboardKey,
	delta_time: f32,
) -> Secret_Sequence_Step {
	result := Secret_Sequence_Step {
		state = state,
	}
	result.state.remaining = max(0, result.state.remaining - max(0, delta_time))
	if result.state.remaining == 0 {
		result.state.matched = 0
	}
	if key == .KEY_NULL do return result
	if result.state.matched < 0 || result.state.matched >= len(SECRET_OVERDRIVE_SEQUENCE) {
		result.state = {}
	}

	expected := SECRET_OVERDRIVE_SEQUENCE[result.state.matched]
	if key == expected {
		result.state.matched += 1
		result.state.remaining = SECRET_SEQUENCE_TIMEOUT
		if result.state.matched == len(SECRET_OVERDRIVE_SEQUENCE) {
			result.state = {}
			result.activated = true
		}
	} else if key == SECRET_OVERDRIVE_SEQUENCE[0] {
		result.state.matched = 1
		result.state.remaining = SECRET_SEQUENCE_TIMEOUT
	} else {
		result.state = {}
	}
	return result
}

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

ghost_pilot_target_lane :: proc(nodes: []Track_Node, current: int, current_lane: f32) -> f32 {
	lane := clamp(current_lane, -1, 1)
	if len(nodes) == 0 || current >= len(nodes) - 1 do return lane
	start := max(0, current + 1)
	end := min(len(nodes), start + GHOST_PILOT_LOOKAHEAD)
	for i in start ..< end {
		if nodes[i].kind == PICKUP do return clamp(f32(nodes[i].lane), -1, 1)
	}
	return lane
}

ghost_pilot_after_manual_input :: proc(active, manual_input: bool) -> bool {
	return active && !manual_input
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

lane_aligned :: proc(player_lane: f32, object_lane: i32) -> bool {
	return abs(player_lane - f32(object_lane)) < LANE_COLLISION_TOLERANCE
}

ship_echo_collects_node :: proc(
	node: Track_Node,
	player_lane, beat_strength, overdrive: f32,
) -> bool {
	if node.kind != PICKUP || overdrive <= 0 do return false
	echo := ship_echo_response(beat_strength, node.pace)
	if echo.strength <= 0 do return false

	road_lane_span := lane_position(node.width, 1)
	if road_lane_span <= 0 do return false
	for layer in 1 ..= SHIP_ECHO_LAYERS {
		geometry := ship_echo_layer(echo, layer)
		normalized_offset := geometry.lateral_offset / road_lane_span
		for side in -1 ..= 1 {
			if side == 0 do continue
			ghost_lane := player_lane + f32(side) * normalized_offset
			if lane_aligned(ghost_lane, node.lane) do return true
		}
	}
	return false
}
