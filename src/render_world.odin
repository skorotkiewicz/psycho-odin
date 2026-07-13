package main

import "core:math"
import rl "vendor:raylib"

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

ride_camera :: proc(
	nodes: []Track_Node,
	current: int,
	fraction, player_lane, steer_lean, shake_x, shake_y: f32,
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
	camera_y := max(
		CHASE_CAMERA_MIN_Y,
		camera_ground_y + 2.55 + abs(turn_preview) * 0.8 + abs(pitch_preview) * 1.2 + shake_y,
	)
	return {
		position = {player_x * 0.72 + shake_x, camera_y, CHASE_CAMERA_Z},
		target = {target_x, target_y + 0.05, target_z},
		up = {-camera_bank, 1, 0},
		fovy = 66 + pace_curve * 18 + turn_fov + pitch_fov,
		projection = .PERSPECTIVE,
	}
}

draw_ride :: proc(
	nodes: []Track_Node,
	current: int,
	fraction, player_lane, steer_lean, pulse, shake: f32,
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
	camera := ride_camera(nodes, current, fraction, player_lane, steer_lean, shake_x, shake_y)
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
			rl.DrawCube(
				{left.x - 1.25, left.y + panel_height * 0.38, center.z},
				0.22,
				panel_height,
				1.7,
				panel_color,
			)
			rl.DrawCube(
				{right.x + 1.25, right.y + panel_height * 0.38, center.z},
				0.22,
				panel_height,
				1.7,
				panel_color,
			)
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
	ship_y := 0.38 - ship_x * base_bank
	ship_color := pace_color(max(0.48, pace + pulse * 0.18), 1)
	trail_count := 9 + int(pace_curve * 14)
	for trail in 1 ..= trail_count {
		alpha := u8(max(7, 125 / trail))
		trail_color := pace_color(pace, 1, alpha)
		trail_point := pitch_around(
			{ship_x + steer_lean * f32(trail) * 0.018, ship_y, -f32(trail) * (0.52 + pace * 0.28)},
			ship_y,
			base_pitch,
		)
		rl.DrawSphere(trail_point, 0.29 / f32(trail) + 0.05, trail_color)
	}
	wing_tilt := steer_lean * 0.24
	body_back := pitch_around({ship_x, ship_y, -0.45}, ship_y, base_pitch)
	body_front := pitch_around({ship_x, ship_y, 2.0}, ship_y, base_pitch)
	rl.DrawCylinderEx(body_back, body_front, 0.56, 0.08, 8, pace_color(pace, 0.46))
	rl.DrawCylinderWiresEx(body_back, body_front, 0.56, 0.08, 8, rl.Color{235, 245, 255, 230})
	ship_nose := pitch_around({ship_x, ship_y, 1.22}, ship_y, base_pitch)
	ship_center := pitch_around({ship_x, ship_y, 0.02}, ship_y, base_pitch)
	ship_left := pitch_around(
		{ship_x - 1.48, ship_y - 0.20 + base_bank * 1.48 + wing_tilt, -0.34},
		ship_y,
		base_pitch,
	)
	ship_right := pitch_around(
		{ship_x + 1.48, ship_y - 0.20 - base_bank * 1.48 - wing_tilt, -0.34},
		ship_y,
		base_pitch,
	)
	rl.DrawTriangle3D(ship_nose, ship_left, ship_center, ship_color)
	rl.DrawTriangle3D(ship_nose, ship_center, ship_right, ship_color)
	for side in -1 ..= 1 {
		if side == 0 do continue
		pod_x := ship_x + f32(side) * 0.55
		pod_y := ship_y - f32(side) * (base_bank * 0.55 + wing_tilt * 0.35)
		pod_back := pitch_around({pod_x, pod_y, -0.46}, ship_y, base_pitch)
		pod_front := pitch_around({pod_x, pod_y, 0.72}, ship_y, base_pitch)
		rl.DrawCylinderEx(pod_back, pod_front, 0.24, 0.13, 7, pace_color(pace, 0.72))
		rl.DrawSphere(pod_back, 0.22 + pace * 0.07, rl.WHITE)
	}
	cockpit := pitch_around({ship_x, ship_y + 0.24, 0.30}, ship_y, base_pitch)
	rl.DrawSphere(cockpit, 0.34 + pulse * 0.10, ship_color)
	rl.DrawSphereWires(cockpit, 0.37 + pulse * 0.10, 7, 7, rl.WHITE)
	rl.EndMode3D()
}
