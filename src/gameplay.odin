package main

import "core:math"
import rl "vendor:raylib"

LANE_COLLISION_TOLERANCE :: f32(0.43)

SECTION_CLEAR_POINTS_PER_NODE :: 10
DRIFT_MIN_BANK :: f32(0.14)
DRIFT_MIN_OUTER_LANE :: f32(0.55)
DRIFT_MAX_POINTS_PER_SECOND :: f32(90)
PLAYBACK_FINISH_CATCHUP_NODES :: 2

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

ride_playback_time :: proc(
	reported_time, previous_time, duration: f32,
	node_count: int,
	finished: bool,
) -> f32 {
	// Stopping a raylib stream resets its clock, including on normal end-of-song.
	playhead := clamp(max(reported_time, previous_time), 0, max(0, duration))
	current := clamp(int(playhead / STEP), 0, max(0, node_count - 1))
	if finished && should_catch_up_final_nodes(current, node_count) do return duration
	return playhead
}

ride_sample_position :: proc(time_played: f32, node_count: int) -> (current: int, fraction: f32) {
	if node_count <= 0 do return
	node_time := max(0, time_played) / STEP
	current = clamp(int(node_time), 0, node_count - 1)
	// The last cached point has no following segment in the ride's base transform.
	if current < node_count - 1 do fraction = clamp(node_time - f32(current), 0, 1)
	return
}

ride_timer_step :: proc(remaining, delta_time: f32, active: bool) -> f32 {
	if !active do return remaining
	return max(0, remaining - max(0, delta_time))
}

should_catch_up_final_nodes :: proc(current, node_count: int) -> bool {
	if node_count <= 0 || current < 0 || current >= node_count do return false
	remaining := node_count - 1 - current
	return remaining <= PLAYBACK_FINISH_CATCHUP_NODES
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

Section_Mastery_State :: struct {
	section_index:                   int,
	node_count, pickup_count:        int,
	pickups_seen, pickups_collected: int,
	missed, active:                  bool,
}

Section_Mastery_Outcome :: struct {
	state:   Section_Mastery_State,
	bonus:   int,
	perfect: bool,
}

section_index_for_node :: proc(node_index: int) -> int {
	return max(0, node_index) / TRACK_SECTION_LENGTH
}

begin_section_mastery :: proc(nodes: []Track_Node, node_index: int) -> Section_Mastery_State {
	if len(nodes) == 0 || node_index < 0 || node_index >= len(nodes) do return {}
	section_index := section_index_for_node(node_index)
	start := section_index * TRACK_SECTION_LENGTH
	end := min(len(nodes), start + TRACK_SECTION_LENGTH)
	state := Section_Mastery_State {
		section_index = section_index,
		node_count    = end - start,
		active        = true,
	}
	for i in start ..< end {
		if nodes[i].kind == PICKUP do state.pickup_count += 1
	}
	return state
}

record_section_pickup :: proc(
	state: Section_Mastery_State,
	collected: bool,
) -> Section_Mastery_State {
	result := state
	if !result.active do return result
	result.pickups_seen = min(result.pickup_count, result.pickups_seen + 1)
	if collected {
		result.pickups_collected = min(result.pickup_count, result.pickups_collected + 1)
	} else {
		result.missed = true
	}
	return result
}

finish_section_mastery :: proc(state: Section_Mastery_State) -> Section_Mastery_Outcome {
	result := Section_Mastery_Outcome {
		state = state,
	}
	result.state.active = false
	result.perfect =
		state.active &&
		state.pickup_count > 0 &&
		state.pickups_seen == state.pickup_count &&
		state.pickups_collected == state.pickup_count &&
		!state.missed
	if result.perfect do result.bonus = state.node_count * SECTION_CLEAR_POINTS_PER_NODE
	return result
}

Drift_Score_Step :: struct {
	residual, rate: f32,
	points:         int,
}

drift_score_rate :: proc(bank, player_lane: f32) -> f32 {
	bank_magnitude := abs(bank)
	if bank_magnitude <= DRIFT_MIN_BANK do return 0
	turn_direction: f32 = 1
	if bank < 0 do turn_direction = -1
	// The outside lane is opposite the direction of the curve.
	outer_lane := -clamp(player_lane, -1, 1) * turn_direction
	if outer_lane <= DRIFT_MIN_OUTER_LANE do return 0
	bank_strength := clamp((bank_magnitude - DRIFT_MIN_BANK) / (0.68 - DRIFT_MIN_BANK), 0, 1)
	lane_strength := clamp((outer_lane - DRIFT_MIN_OUTER_LANE) / (1 - DRIFT_MIN_OUTER_LANE), 0, 1)
	return DRIFT_MAX_POINTS_PER_SECOND * bank_strength * lane_strength
}

drift_score_step :: proc(residual, bank, player_lane, delta_time: f32) -> Drift_Score_Step {
	result := Drift_Score_Step {
		residual = clamp(residual, 0, 0.999999),
		rate     = drift_score_rate(bank, player_lane),
	}
	if result.rate <= 0 || delta_time <= 0 do return result
	total := result.residual + result.rate * delta_time
	result.points = int(total)
	result.residual = total - f32(result.points)
	return result
}

drift_score_interval :: proc(
	nodes: []Track_Node,
	residual, player_lane, start_time, end_time: f32,
) -> Drift_Score_Step {
	result := Drift_Score_Step {
		residual = clamp(residual, 0, 0.999999),
	}
	start := max(0, start_time)
	finish := max(start, end_time)
	if len(nodes) == 0 || finish <= start do return result

	first_sample := max(0, int(start / STEP))
	last_sample := max(first_sample, int(finish / STEP))
	for sample_i in first_sample ..= last_sample {
		segment_start := max(start, f32(sample_i) * STEP)
		segment_end := min(finish, f32(sample_i + 1) * STEP)
		segment_duration := segment_end - segment_start
		if segment_duration <= 0 do continue
		node_i := clamp(sample_i, 0, len(nodes) - 1)
		step := drift_score_step(
			result.residual,
			road_bank(nodes, node_i),
			player_lane,
			segment_duration,
		)
		result.residual = step.residual
		result.points += step.points
	}
	end_node := clamp(int(max(start, finish - 0.000001) / STEP), 0, len(nodes) - 1)
	result.rate = drift_score_rate(road_bank(nodes, end_node), player_lane)
	return result
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
