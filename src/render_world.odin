package main

import "core:math"
import rl "vendor:raylib"

street_bulb_radius :: proc(rhythm_pulse: f32) -> f32 {
	return 0.60 + clamp(rhythm_pulse, 0, 1) * 0.40
}

street_bulb_aura_alpha :: proc(rhythm_pulse: f32) -> u8 {
	return 128 + u8(clamp(rhythm_pulse, 0, 1) * 112)
}

Rhythm_Kick :: struct {
	impact, rebound: f32,
}

Rhythm_Push :: struct {
	impact, rebound, velocity: f32,
}

Rhythm_Motion :: struct {
	kick: Rhythm_Kick,
	push: Rhythm_Push,
}

SHIP_ECHO_BEAT_THRESHOLD :: f32(0.16)
SHIP_ECHO_LAYERS :: 3

Ship_Echo_Response :: struct {
	strength, spread, depth: f32,
}

ship_echo_response :: proc(beat_strength, pace: f32) -> Ship_Echo_Response {
	normalized := clamp(
		(beat_strength - SHIP_ECHO_BEAT_THRESHOLD) / (1 - SHIP_ECHO_BEAT_THRESHOLD),
		0,
		1,
	)
	strength := normalized * normalized * (3 - 2 * normalized)
	reach := f32(math.sqrt(f64(strength)))
	clamped_pace := clamp(pace, 0, 1)
	return {
		strength = strength,
		spread = reach * (0.75 + clamped_pace * 0.85),
		depth = reach * (0.55 + clamped_pace * 0.45),
	}
}

ship_echo_rhythm_strength :: proc(rhythm: Rhythm_Motion) -> f32 {
	impact := max(rhythm.kick.impact, rhythm.push.impact)
	rebound := max(rhythm.kick.rebound * 1.5, max(0, rhythm.push.rebound) * 2.6)
	return clamp(max(impact, rebound), 0, 1)
}

rhythm_kick_response :: proc(accent, bass, fraction, visual_strength: f32) -> Rhythm_Kick {
	phase := clamp(fraction, 0, 1)
	strength := clamp(visual_strength, 0, 1)
	power := clamp(accent, 0, 1) * (0.72 + clamp(bass, 0, 1) * 0.42) * strength
	power = clamp(power, 0, 1)
	remaining := 1 - phase
	return {
		impact = power * remaining * remaining * remaining,
		rebound = power * f32(math.sin(f64(phase * f32(math.PI)))) * remaining,
	}
}

rhythm_impulse_strength :: proc(accent, bass, visual_strength: f32) -> f32 {
	strength := clamp(visual_strength, 0, 1)
	power := clamp(accent, 0, 1) * (0.72 + clamp(bass, 0, 1) * 0.42) * strength
	return clamp(power, 0, 1)
}

rhythm_push_step :: proc(
	push: Rhythm_Push,
	impulse, delta_time: f32,
	active: bool,
) -> Rhythm_Push {
	if !active || delta_time <= 0 {
		return push
	}

	dt := clamp(delta_time, 0, 0.05)
	next := push
	next.impact = max(0, next.impact - dt * 5.4)
	force := clamp(impulse, 0, 1)
	if force > 0 {
		next.impact = max(next.impact, force)
		// Velocity accumulation lets consecutive strong beats genuinely shove the
		// craft instead of restarting the same canned animation every track slice.
		next.velocity = clamp(next.velocity + force * 4.2, -4.5, 6.2)
	}

	acceleration := -next.rebound * 52 - next.velocity * 8.5
	next.velocity = clamp(next.velocity + acceleration * dt, -4.5, 6.2)
	next.rebound = clamp(next.rebound + next.velocity * dt, -0.12, 0.42)
	if next.impact < 0.0005 do next.impact = 0
	if abs(next.rebound) < 0.0005 && abs(next.velocity) < 0.0005 {
		next.rebound, next.velocity = 0, 0
	}
	return next
}

draw_ship_echo_edge :: proc(start, end: rl.Vector3, scale: f32, color: rl.Color) {
	thickness := 0.020 * scale
	rl.DrawCylinderEx(start, end, thickness, thickness, 4, color)
}

draw_ship_echo_ghost :: proc(
	ship_x, ship_y, ship_z, base_pitch, base_bank, wing_tilt, scale: f32,
	fill_color, wire_color: rl.Color,
) {
	wing_width := 1.48 * scale
	nose := pitch_around({ship_x, ship_y, ship_z + 1.22 * scale}, ship_y, base_pitch)
	center := pitch_around({ship_x, ship_y, ship_z + 0.02 * scale}, ship_y, base_pitch)
	tail := pitch_around({ship_x, ship_y, ship_z - 0.46 * scale}, ship_y, base_pitch)
	left := pitch_around(
		{
			ship_x - wing_width,
			ship_y - 0.20 * scale + base_bank * wing_width + wing_tilt * scale,
			ship_z - 0.34 * scale,
		},
		ship_y,
		base_pitch,
	)
	right := pitch_around(
		{
			ship_x + wing_width,
			ship_y - 0.20 * scale - base_bank * wing_width - wing_tilt * scale,
			ship_z - 0.34 * scale,
		},
		ship_y,
		base_pitch,
	)

	rl.DrawTriangle3D(nose, left, center, fill_color)
	rl.DrawTriangle3D(nose, center, right, fill_color)
	draw_ship_echo_edge(nose, left, scale, wire_color)
	draw_ship_echo_edge(left, tail, scale, wire_color)
	draw_ship_echo_edge(tail, right, scale, wire_color)
	draw_ship_echo_edge(right, nose, scale, wire_color)
	draw_ship_echo_edge(tail, nose, scale, wire_color)
	cockpit := pitch_around(
		{ship_x, ship_y + 0.24 * scale, ship_z + 0.30 * scale},
		ship_y,
		base_pitch,
	)
	rl.DrawSphere(cockpit, 0.30 * scale, fill_color)
	rl.DrawSphereWires(cockpit, 0.34 * scale, 6, 6, wire_color)
}

draw_ship_echoes :: proc(
	ship_x, ship_y, ship_z, base_pitch, base_bank, wing_tilt, pace, beat_strength: f32,
) {
	echo := ship_echo_response(beat_strength, pace)
	if echo.strength <= 0 do return

	rl.BeginBlendMode(.ADDITIVE)
	defer rl.EndBlendMode()
	visibility := f32(math.sqrt(f64(echo.strength)))
	// Draw the oldest ghosts first so their transparent silhouettes layer cleanly.
	for echo_index in 0 ..< SHIP_ECHO_LAYERS {
		layer := SHIP_ECHO_LAYERS - echo_index
		layer_f := f32(layer)
		spread_scale := 0.65 + (layer_f - 1) * 0.35
		depth_scale := 0.65 + (layer_f - 1) * 0.40
		ghost_z := ship_z - layer_f * 0.18 - echo.depth * depth_scale
		ghost_scale := 0.92 - (layer_f - 1) * 0.10
		wire_alpha := u8(clamp(visibility * (190 - (layer_f - 1) * 24), 0, 255))
		fill_alpha := u8(clamp(echo.strength * (70 - (layer_f - 1) * 10), 0, 255))

		for side in -1 ..= 1 {
			if side == 0 do continue
			ghost_x := ship_x + f32(side) * echo.spread * spread_scale
			fill_color := pace_color(pace, 1, fill_alpha)
			wire_color := pace_color(pace, 1, wire_alpha)
			if side > 0 {
				fill_color = pace_opposite_color(pace, 1, fill_alpha)
				wire_color = pace_opposite_color(pace, 1, wire_alpha)
			}
			draw_ship_echo_ghost(
				ghost_x,
				ship_y,
				ghost_z,
				base_pitch,
				base_bank,
				wing_tilt,
				ghost_scale,
				fill_color,
				wire_color,
			)
		}
	}
}

PSYCHO_SHADER :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
out vec4 finalColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform float time;
uniform float energy;
uniform float pulse;
uniform float amount;

void main() {
    vec2 p = fragTexCoord - 0.5;
    float radius = length(p);
    float wave = sin(fragTexCoord.y*19.0 + time*1.3) * 0.0035 * amount * (0.25 + energy);
    vec2 uv = fragTexCoord + vec2(wave + p.y*p.x*0.018*amount, sin(radius*28.0-time)*0.0015*amount);
    float split = (0.0015 + pulse*0.0045) * amount;
    vec3 color;
    color.r = texture(texture0, uv + vec2(split, 0.0)).r;
    color.g = texture(texture0, uv).g;
    color.b = texture(texture0, uv - vec2(split, 0.0)).b;
    float vignette = smoothstep(0.82, 0.18, radius);
    float scan = 0.96 + 0.04*sin(fragTexCoord.y*900.0);
    finalColor = vec4(color * (0.72 + 0.28*vignette) * scan, 1.0) * colDiffuse * fragColor;
}`

draw_street_bulb :: proc(position: rl.Vector3, pace, rhythm_pulse: f32) {
	pulse := clamp(rhythm_pulse, 0, 1)
	radius := street_bulb_radius(pulse)
	glow_color := pace_opposite_color(pace, 1, 255)
	aura_color := pace_opposite_color(pace, 1, street_bulb_aura_alpha(pulse))
	wire_color := pace_opposite_color(pace, 0.88, 235)
	rl.DrawSphere(position, radius + 0.34 + pulse * 0.16, aura_color)
	rl.DrawSphere(position, radius, glow_color)
	rl.DrawSphereWires(position, radius + 0.07, 7, 7, wire_color)
}

ride_camera :: proc(
	nodes: []Track_Node,
	current: int,
	fraction, player_lane, steer_lean, shake_x, shake_y: f32,
	rhythm: Rhythm_Motion,
) -> rl.Camera3D {
	next_i := min(current + 1, len(nodes) - 1)
	base_x := nodes[current].curve_x + (nodes[next_i].curve_x - nodes[current].curve_x) * fraction
	base_y := nodes[current].curve_y + (nodes[next_i].curve_y - nodes[current].curve_y) * fraction
	base_z := nodes[current].curve_z + (nodes[next_i].curve_z - nodes[current].curve_z) * fraction
	base_heading :=
		nodes[current].heading + (nodes[next_i].heading - nodes[current].heading) * fraction
	base_pitch := nodes[current].pitch + (nodes[next_i].pitch - nodes[current].pitch) * fraction
	base_width := nodes[current].width + (nodes[next_i].width - nodes[current].width) * fraction
	base_bank :=
		road_bank(nodes, current) +
		(road_bank(nodes, next_i) - road_bank(nodes, current)) * fraction
	playhead := f32(current) + fraction
	pace := pace_sample(nodes, playhead)
	pace_curve := pace * pace * (3 - 2 * pace)
	near_position := playhead + 8
	far_position := playhead + 18 + pace * 8
	preview_position := playhead + 10
	near_look := road_center_sample(nodes, near_position, base_x, base_y, base_z, base_heading)
	far_look := road_center_sample(nodes, far_position, base_x, base_y, base_z, base_heading)
	future_heading := unwrap_angle_near(heading_sample(nodes, preview_position), base_heading)
	future_pitch := pitch_sample(nodes, preview_position)
	turn_preview := clamp(future_heading - base_heading, -0.7, 0.7)
	pitch_preview := clamp(future_pitch - base_pitch, -0.45, 0.45)
	camera_bank := clamp(turn_preview * 0.48 + steer_lean * 0.035, -0.29, 0.29)
	player_x := lane_position(base_width, player_lane)
	// A chase camera should lag the route. Fully aiming at the far centerline mathematically
	// cancels the yaw/pitch that the player needs to see in order to feel the rollercoaster.
	target_x := clamp(near_look.x * 0.10 + far_look.x * 0.18, -18, 18) + player_x * 0.06
	target_y := clamp(near_look.y * 0.08 + far_look.y * 0.14, -12, 12)
	// Using the full far Z here would dilute X/Y as fast nodes spread farther apart.
	target_z := max(24, near_look.z * 0.10 + far_look.z * 0.18)
	turn_fov := min(11, abs(turn_preview) * 24)
	pitch_fov := min(8, abs(pitch_preview) * 24)
	camera_ground_y := -(player_x * 0.72) * base_bank
	base_camera_y := max(
		CHASE_CAMERA_MIN_Y,
		camera_ground_y +
		2.55 +
		max(0, -base_pitch) * 12 +
		abs(turn_preview) * 0.8 +
		abs(pitch_preview) * 1.2 +
		shake_y,
	)
	camera_y := max(
		CHASE_CAMERA_MIN_Y,
		base_camera_y + rhythm.kick.rebound * 0.14 + max(0, rhythm.push.rebound) * 0.32,
	)
	camera_z := CHASE_CAMERA_Z + rhythm.kick.impact * 0.30 + rhythm.push.impact * 0.62
	return {
		position = {player_x * 0.72 + shake_x, camera_y, camera_z},
		target = {target_x, target_y + 0.05, target_z},
		up = {-camera_bank, 1, 0},
		fovy = 66 +
		pace_curve * 18 +
		turn_fov +
		pitch_fov +
		rhythm.kick.impact * 2.8 +
		rhythm.push.impact * 4.8,
		projection = .PERSPECTIVE,
	}
}

draw_ride :: proc(
	nodes: []Track_Node,
	current: int,
	fraction, player_lane, steer_lean, pulse, shake: f32,
	rhythm: Rhythm_Motion,
	overdrive: f32,
) {
	next_i := min(current + 1, len(nodes) - 1)
	base_x := nodes[current].curve_x + (nodes[next_i].curve_x - nodes[current].curve_x) * fraction
	base_y := nodes[current].curve_y + (nodes[next_i].curve_y - nodes[current].curve_y) * fraction
	base_z := nodes[current].curve_z + (nodes[next_i].curve_z - nodes[current].curve_z) * fraction
	base_heading :=
		nodes[current].heading + (nodes[next_i].heading - nodes[current].heading) * fraction
	base_pitch := nodes[current].pitch + (nodes[next_i].pitch - nodes[current].pitch) * fraction
	base_width := nodes[current].width + (nodes[next_i].width - nodes[current].width) * fraction
	base_bank :=
		road_bank(nodes, current) +
		(road_bank(nodes, next_i) - road_bank(nodes, current)) * fraction
	shake_x := f32(math.sin(rl.GetTime() * 61)) * shake * 0.24
	shake_y := f32(math.sin(rl.GetTime() * 47)) * shake * 0.18
	playhead := f32(current) + fraction
	pace := pace_sample(nodes, playhead)
	pace_curve := pace * pace * (3 - 2 * pace)
	player_x := lane_position(base_width, player_lane)
	camera := ride_camera(
		nodes,
		current,
		fraction,
		player_lane,
		steer_lean,
		shake_x,
		shake_y,
		rhythm,
	)
	rl.BeginMode3D(camera)

	closed_track := track_is_closed(nodes)
	unique_nodes := len(nodes)
	if closed_track do unique_nodes -= 1
	visible_segments := min(100, max(0, len(nodes) - 1 - current))
	if closed_track do visible_segments = min(100, unique_nodes)
	render_segments := visible_segments
	if render_segments > 0 do render_segments += 1
	rear_near_position := road_near_sample_position(
		nodes,
		playhead,
		base_x,
		base_y,
		base_z,
		base_heading,
	)
	for render_segment in 0 ..< render_segments {
		course_segment := max(0, render_segment - 1)
		is_rear_skirt := render_segment == 0
		i := current + course_segment
		if closed_track do i %= unique_nodes
		node := nodes[i]
		road_near_position := f32(current + course_segment)
		road_far_position := f32(current + course_segment + 1)
		if is_rear_skirt {
			road_near_position = rear_near_position
			road_far_position = playhead
		} else if course_segment == 0 {
			road_near_position = playhead
		}
		near_width := width_sample(nodes, road_near_position)
		far_width := width_sample(nodes, road_far_position)
		left := road_point_sample(
			nodes,
			road_near_position,
			-near_width,
			base_x,
			base_y,
			base_z,
			base_heading,
		)
		right := road_point_sample(
			nodes,
			road_near_position,
			near_width,
			base_x,
			base_y,
			base_z,
			base_heading,
		)
		next_left := road_point_sample(
			nodes,
			road_far_position,
			-far_width,
			base_x,
			base_y,
			base_z,
			base_heading,
		)
		next_right := road_point_sample(
			nodes,
			road_far_position,
			far_width,
			base_x,
			base_y,
			base_z,
			base_heading,
		)
		center := road_point(nodes, i, 0, base_x, base_y, base_z, base_heading)
		surface_value := clamp(
			0.19 + node.pace * 0.28 + node.energy * 0.28 + node.mid * 0.20,
			0,
			0.82,
		)
		// Shade each lane independently: this makes steering and traffic readable at speed.
		for lane_i in 0 ..< 3 {
			near_left_offset := -near_width + f32(lane_i) * near_width * 2 / 3
			near_right_offset := -near_width + f32(lane_i + 1) * near_width * 2 / 3
			far_left_offset := -far_width + f32(lane_i) * far_width * 2 / 3
			far_right_offset := -far_width + f32(lane_i + 1) * far_width * 2 / 3
			lane_left := road_point_sample(
				nodes,
				road_near_position,
				near_left_offset,
				base_x,
				base_y,
				base_z,
				base_heading,
			)
			lane_right := road_point_sample(
				nodes,
				road_near_position,
				near_right_offset,
				base_x,
				base_y,
				base_z,
				base_heading,
			)
			lane_next_left := road_point_sample(
				nodes,
				road_far_position,
				far_left_offset,
				base_x,
				base_y,
				base_z,
				base_heading,
			)
			lane_next_right := road_point_sample(
				nodes,
				road_far_position,
				far_right_offset,
				base_x,
				base_y,
				base_z,
				base_heading,
			)
			lane_lift: f32
			if lane_i == 1 do lane_lift = 0.045
			lane_color := pace_color(node.pace, surface_value + lane_lift, 225)
			rl.DrawTriangle3D(lane_left, lane_next_left, lane_right, lane_color)
			rl.DrawTriangle3D(lane_right, lane_next_left, lane_next_right, lane_color)
		}

		rail_color := pace_color(node.pace, 0.78 + node.pace * 0.2, 245)
		rl.DrawCylinderEx(left, next_left, 0.045 + node.pace * 0.025, 0.045, 5, rail_color)
		rl.DrawCylinderEx(right, next_right, 0.045 + node.pace * 0.025, 0.045, 5, rail_color)
		if i % 2 == 0 {
			for lane_mark in -1 ..= 1 {
				if lane_mark == 0 do continue
				mark := f32(lane_mark) * near_width / 3
				next_mark := f32(lane_mark) * far_width / 3
				p0 := road_point_sample(
					nodes,
					road_near_position,
					mark,
					base_x,
					base_y,
					base_z,
					base_heading,
				)
				p1 := road_point_sample(
					nodes,
					road_far_position,
					next_mark,
					base_x,
					base_y,
					base_z,
					base_heading,
				)
				rl.DrawLine3D(
					lift_road_overlay(p0, 0.055),
					lift_road_overlay(p1, 0.055),
					rl.Color{205, 225, 255, 145},
				)
			}
		}
		if node.kind != 0 && course_segment > 1 {
			object := road_point(
				nodes,
				i,
				lane_position(node.width, f32(node.lane)),
				base_x,
				base_y,
				base_z,
				base_heading,
			)
			object.y += 0.75
			if node.kind == PICKUP {
				pickup_colors := [3]rl.Color {
					{255, 75, 90, 255},
					{60, 235, 255, 255},
					{205, 85, 255, 255},
				}
				orb_color := pickup_colors[clamp(node.tone, 0, 2)]
				rl.DrawSphere(object, 0.24 + node.beat * 0.3, orb_color)
				rl.DrawSphereWires(object, 0.55 + node.beat * 0.35, 7, 7, rl.WHITE)
			} else if node.kind == HAZARD {
				rl.DrawCube(object, 1.25, 1.35, 1.25, rl.Color{245, 40, 72, 235})
				rl.DrawCubeWires(object, 1.55, 1.65, 1.55, rl.Color{255, 190, 60, 255})
			} else if node.kind == SHIELD {
				rl.DrawSphere(object, 0.62, rl.Color{70, 255, 145, 255})
				rl.DrawSphereWires(object, 0.9, 8, 8, rl.WHITE)
			} else {
				rl.DrawCube(object, 0.85, 0.85, 0.85, rl.Color{255, 215, 45, 255})
				rl.DrawCubeWires(object, 1.25, 1.25, 1.25, rl.WHITE)
			}
		}

		if !is_rear_skirt && node.section == DROP && i % 7 == 0 {
			tower_color := pace_color(node.pace, 0.38 + node.energy * 0.36, 180)
			rl.DrawCube({left.x - 2.5, left.y - 3.5, center.z}, 1.2, 7, 1.2, tower_color)
			rl.DrawCube({right.x + 2.5, right.y - 3.5, center.z}, 1.2, 7, 1.2, tower_color)
		}
		if !is_rear_skirt && i % 6 == 0 {
			panel_height := 1.5 + node.energy * 3.5 + node.pace * 1.8
			panel_color := pace_color(node.pace, 0.34 + node.pace * 0.35, 135)
			left_panel := rl.Vector3{left.x - 1.25, left.y + panel_height * 0.38, center.z}
			right_panel := rl.Vector3{right.x + 1.25, right.y + panel_height * 0.38, center.z}
			rl.DrawCube(left_panel, 0.22, panel_height, 1.7, panel_color)
			rl.DrawCube(right_panel, 0.22, panel_height, 1.7, panel_color)
			bulb_lift := panel_height * 0.50 + 0.12
			left_bulb := left_panel
			right_bulb := right_panel
			left_bulb.y += bulb_lift
			right_bulb.y += bulb_lift
			lamp_pulse := max(rhythm.kick.impact, rhythm.push.impact)
			draw_street_bulb(left_bulb, node.pace, lamp_pulse)
			draw_street_bulb(right_bulb, node.pace, lamp_pulse)
		}
		if !is_rear_skirt && i % 5 == 0 {
			star_x := f32(((i * 73) % 31) - 15) * 1.6
			star_y := f32(((i * 47) % 17) - 3) * 1.2
			star_color := pace_color(node.pace, 0.62 + node.high * 0.35, 180)
			rl.DrawSphere({star_x, star_y, center.z}, 0.035 + node.high * 0.08, star_color)
			if node.pace > 0.32 {
				rl.DrawLine3D(
					{star_x, star_y, center.z},
					{star_x, star_y, center.z - 2 - node.pace * 8},
					star_color,
				)
			}
		}
	}

	ship_x := player_x
	ship_y :=
		0.38 -
		ship_x * base_bank -
		rhythm.kick.impact * 0.10 +
		rhythm.kick.rebound * 0.28 +
		rhythm.push.rebound * 0.82
	ship_z := rhythm.push.impact * 0.18 + rhythm.push.rebound * 0.78
	ship_color := pace_color(
		max(0.48, pace + pulse * 0.18 + rhythm.kick.impact * 0.10 + rhythm.push.impact * 0.07),
		1,
	)
	wing_tilt := steer_lean * 0.24
	trail_count := 9 + int(pace_curve * 14)
	trail_spacing := 0.52 + pace * 0.28 + rhythm.kick.impact * 0.22 + rhythm.push.impact * 0.42
	for trail in 1 ..= trail_count {
		alpha := u8(max(7, 125 / trail))
		trail_color := pace_color(pace, 1, alpha)
		trail_point := pitch_around(
			{
				ship_x + steer_lean * f32(trail) * 0.018,
				ship_y,
				ship_z - f32(trail) * trail_spacing,
			},
			ship_y,
			base_pitch,
		)
		rl.DrawSphere(trail_point, 0.29 / f32(trail) + 0.05, trail_color)
	}
	if overdrive > 0 do draw_ship_echoes(ship_x, ship_y, ship_z, base_pitch, base_bank, wing_tilt, pace, ship_echo_rhythm_strength(rhythm))
	body_back := pitch_around({ship_x, ship_y, ship_z - 0.45}, ship_y, base_pitch)
	body_front := pitch_around({ship_x, ship_y, ship_z + 2.0}, ship_y, base_pitch)
	rl.DrawCylinderEx(body_back, body_front, 0.56, 0.08, 8, pace_color(pace, 0.46))
	rl.DrawCylinderWiresEx(body_back, body_front, 0.56, 0.08, 8, rl.Color{235, 245, 255, 230})
	ship_nose := pitch_around({ship_x, ship_y, ship_z + 1.22}, ship_y, base_pitch)
	ship_center := pitch_around({ship_x, ship_y, ship_z + 0.02}, ship_y, base_pitch)
	ship_left := pitch_around(
		{ship_x - 1.48, ship_y - 0.20 + base_bank * 1.48 + wing_tilt, ship_z - 0.34},
		ship_y,
		base_pitch,
	)
	ship_right := pitch_around(
		{ship_x + 1.48, ship_y - 0.20 - base_bank * 1.48 - wing_tilt, ship_z - 0.34},
		ship_y,
		base_pitch,
	)
	rl.DrawTriangle3D(ship_nose, ship_left, ship_center, ship_color)
	rl.DrawTriangle3D(ship_nose, ship_center, ship_right, ship_color)
	for side in -1 ..= 1 {
		if side == 0 do continue
		pod_x := ship_x + f32(side) * 0.55
		pod_y := ship_y - f32(side) * (base_bank * 0.55 + wing_tilt * 0.35)
		pod_back := pitch_around({pod_x, pod_y, ship_z - 0.46}, ship_y, base_pitch)
		pod_front := pitch_around({pod_x, pod_y, ship_z + 0.72}, ship_y, base_pitch)
		rl.DrawCylinderEx(pod_back, pod_front, 0.24, 0.13, 7, pace_color(pace, 0.72))
		rl.DrawSphere(
			pod_back,
			0.22 + pace * 0.07 + rhythm.kick.impact * 0.06 + rhythm.push.impact * 0.08,
			rl.WHITE,
		)
	}
	cockpit := pitch_around({ship_x, ship_y + 0.24, ship_z + 0.30}, ship_y, base_pitch)
	cockpit_kick := rhythm.kick.impact * 0.05 + rhythm.push.impact * 0.07
	rl.DrawSphere(cockpit, 0.34 + pulse * 0.10 + cockpit_kick, ship_color)
	rl.DrawSphereWires(cockpit, 0.37 + pulse * 0.10 + cockpit_kick, 7, 7, rl.WHITE)
	rl.EndMode3D()
}
