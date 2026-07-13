package main

import "core:math"
import rl "vendor:raylib"

CHASE_CAMERA_Z :: f32(-6.35)
CHASE_CAMERA_MIN_Y :: f32(2.25)
ROAD_CAMERA_CLEARANCE :: f32(1.5)

closure_correction :: proc(value_delta, derivative_delta, u: f32) -> f32 {
	u2 := u * u
	u3 := u2 * u
	// Cubic Hermite correction closes both value and first derivative at the seam.
	return (-2 * u3 + 3 * u2) * value_delta + (u3 - u2) * derivative_delta
}

close_track_loop :: proc(nodes: []Track_Node) {
	count := len(nodes)
	if count < 4 do return
	last_i := count - 1
	first_distance := nodes[0].distance
	raw_length := nodes[last_i].distance - first_distance
	if raw_length <= 0.001 do return

	first_u := clamp((nodes[1].distance - first_distance) / raw_length, 0.000001, 1)
	last_u := clamp((nodes[last_i - 1].distance - first_distance) / raw_length, 0, 0.999999)
	start_dxdu := (nodes[1].curve_x - nodes[0].curve_x) / first_u
	end_dxdu := (nodes[last_i].curve_x - nodes[last_i - 1].curve_x) / (1 - last_u)
	start_dydu := (nodes[1].curve_y - nodes[0].curve_y) / first_u
	end_dydu := (nodes[last_i].curve_y - nodes[last_i - 1].curve_y) / (1 - last_u)
	delta_x := nodes[last_i].curve_x - nodes[0].curve_x
	delta_y := nodes[last_i].curve_y - nodes[0].curve_y

	wrapped := make([]rl.Vector3, count)
	defer delete(wrapped)
	tau := f32(2 * math.PI)
	// The three radial lobes produce broad curvature reversals while remaining a single,
	// non-self-intersecting loop. The scale keeps its circumference close to the open ride.
	loop_radius := max(24, raw_length / (tau * 1.08))
	start_radius := loop_radius * 1.16
	for i in 0 ..< count {
		u := clamp((nodes[i].distance - first_distance) / raw_length, 0, 1)
		theta := u * tau
		raw_radial :=
			nodes[i].curve_x -
			nodes[0].curve_x -
			closure_correction(delta_x, end_dxdu - start_dxdu, u)
		raw_height :=
			nodes[i].curve_y -
			nodes[0].curve_y -
			closure_correction(delta_y, end_dydu - start_dydu, u)
		radial_music := clamp(raw_radial * 0.35, -loop_radius * 0.10, loop_radius * 0.10)
		radius := loop_radius * (1 + 0.16 * f32(math.cos(f64(theta * 3)))) + radial_music
		loop_height :=
			loop_radius *
			(0.055 * f32(math.sin(f64(theta))) - 0.028 * f32(math.sin(f64(theta * 2))))
		music_height := clamp(raw_height * 1.15, -loop_radius * 0.28, loop_radius * 0.28)
		wrapped[i] = {
			start_radius - radius * f32(math.cos(f64(theta))),
			loop_height + music_height,
			radius * f32(math.sin(f64(theta))),
		}
	}
	// Avoid a tiny floating-point crack from sin/cos(2*pi).
	wrapped[last_i] = wrapped[0]
	for i in 0 ..< count {
		nodes[i].curve_x = wrapped[i].x
		nodes[i].curve_y = wrapped[i].y
		nodes[i].curve_z = wrapped[i].z
	}

	// Blend the final road width into the starting width so the physical strip also closes.
	seam_nodes := min(16, max(2, count / 4))
	for offset in 0 ..< seam_nodes {
		i := last_i - offset
		t := 1 - f32(offset) / f32(seam_nodes)
		t = t * t * (3 - 2 * t)
		nodes[i].width += (nodes[0].width - nodes[i].width) * t
	}
	nodes[last_i].width = nodes[0].width

	// Rebuild true 3D arc length after wrapping.
	nodes[0].distance = 0
	distance: f32
	for i in 1 ..< count {
		dx := nodes[i].curve_x - nodes[i - 1].curve_x
		dy := nodes[i].curve_y - nodes[i - 1].curve_y
		dz := nodes[i].curve_z - nodes[i - 1].curve_z
		distance += f32(math.sqrt(f64(dx * dx + dy * dy + dz * dz)))
		nodes[i].distance = distance
	}

	// Cache outgoing tangents and unwrap yaw continuously through the full revolution.
	previous_heading: f32
	for i in 0 ..< last_i {
		dx := nodes[i + 1].curve_x - nodes[i].curve_x
		dy := nodes[i + 1].curve_y - nodes[i].curve_y
		dz := nodes[i + 1].curve_z - nodes[i].curve_z
		planar_step := f32(math.sqrt(f64(dx * dx + dz * dz)))
		heading := f32(math.atan2(f64(dx), f64(dz)))
		if i > 0 {
			for heading - previous_heading > f32(math.PI) do heading -= tau
			for heading - previous_heading < -f32(math.PI) do heading += tau
		}
		nodes[i].heading = heading
		nodes[i].pitch = f32(math.atan2(f64(dy), f64(max(0.001, planar_step))))
		previous_heading = heading
	}
	seam_heading := nodes[0].heading
	for seam_heading - previous_heading > f32(math.PI) do seam_heading -= tau
	for seam_heading - previous_heading < -f32(math.PI) do seam_heading += tau
	nodes[last_i].heading = seam_heading
	nodes[last_i].pitch = nodes[0].pitch
}

road_bank :: proc(nodes: []Track_Node, i: int) -> f32 {
	node_i := clamp(i, 0, len(nodes) - 1)
	if len(nodes) < 3 do return 0
	if track_is_closed(nodes) && (node_i == 0 || node_i == len(nodes) - 1) {
		reference := nodes[node_i].heading
		previous_heading := unwrap_angle_near(nodes[len(nodes) - 2].heading, reference)
		next_heading := unwrap_angle_near(nodes[1].heading, reference)
		return clamp((next_heading - previous_heading) * 3.6, -0.68, 0.68)
	}
	previous := nodes[max(0, node_i - 1)]
	next := nodes[min(len(nodes) - 1, node_i + 1)]
	return clamp((next.heading - previous.heading) * 3.6, -0.68, 0.68)
}

track_is_closed :: proc(nodes: []Track_Node) -> bool {
	if len(nodes) < 2 do return false
	first, last := nodes[0], nodes[len(nodes) - 1]
	dx := last.curve_x - first.curve_x
	dy := last.curve_y - first.curve_y
	dz := last.curve_z - first.curve_z
	return dx * dx + dy * dy + dz * dz < 0.0001
}

wrapped_angle_delta :: proc(angle, reference: f32) -> f32 {
	delta := angle - reference
	return f32(math.atan2(f64(math.sin(f64(delta))), f64(math.cos(f64(delta)))))
}

unwrap_angle_near :: proc(angle, reference: f32) -> f32 {
	return reference + wrapped_angle_delta(angle, reference)
}

road_point :: proc(
	nodes: []Track_Node,
	i: int,
	offset, base_x, base_y, base_z, base_heading: f32,
) -> rl.Vector3 {
	node := nodes[clamp(i, 0, len(nodes) - 1)]
	bank := road_bank(nodes, i)
	node_cos := f32(math.cos(f64(node.heading)))
	node_sin := f32(math.sin(f64(node.heading)))
	world_x := node.curve_x + offset * node_cos
	world_z := node.curve_z - offset * node_sin
	dx, dz := world_x - base_x, world_z - base_z
	base_cos := f32(math.cos(f64(base_heading)))
	base_sin := f32(math.sin(f64(base_heading)))
	return {
		dx * base_cos - dz * base_sin,
		node.curve_y - base_y - offset * bank,
		dx * base_sin + dz * base_cos,
	}
}

track_sample_indices :: proc(
	nodes: []Track_Node,
	node_position: f32,
) -> (
	i, next_i: int,
	fraction: f32,
) {
	position := node_position
	if track_is_closed(nodes) {
		span := f32(len(nodes) - 1)
		for position > span do position -= span
		for position < 0 do position += span
	} else {
		position = clamp(position, 0, f32(len(nodes) - 1))
	}
	i = int(position)
	next_i = min(i + 1, len(nodes) - 1)
	if track_is_closed(nodes) && i == len(nodes) - 1 do next_i = min(1, len(nodes) - 1)
	fraction = position - f32(i)
	return
}

road_point_sample :: proc(
	nodes: []Track_Node,
	node_position, offset, base_x, base_y, base_z, base_heading: f32,
) -> rl.Vector3 {
	i, next_i, fraction := track_sample_indices(nodes, node_position)
	center_x := nodes[i].curve_x + (nodes[next_i].curve_x - nodes[i].curve_x) * fraction
	center_y := nodes[i].curve_y + (nodes[next_i].curve_y - nodes[i].curve_y) * fraction
	center_z := nodes[i].curve_z + (nodes[next_i].curve_z - nodes[i].curve_z) * fraction
	heading :=
		nodes[i].heading + wrapped_angle_delta(nodes[next_i].heading, nodes[i].heading) * fraction
	bank := road_bank(nodes, i) + (road_bank(nodes, next_i) - road_bank(nodes, i)) * fraction
	node_cos := f32(math.cos(f64(heading)))
	node_sin := f32(math.sin(f64(heading)))
	world_x := center_x + offset * node_cos
	world_z := center_z - offset * node_sin
	dx, dz := world_x - base_x, world_z - base_z
	base_cos := f32(math.cos(f64(base_heading)))
	base_sin := f32(math.sin(f64(base_heading)))
	return {
		dx * base_cos - dz * base_sin,
		center_y - base_y - offset * bank,
		dx * base_sin + dz * base_cos,
	}
}

width_sample :: proc(nodes: []Track_Node, node_position: f32) -> f32 {
	i, next_i, fraction := track_sample_indices(nodes, node_position)
	return nodes[i].width + (nodes[next_i].width - nodes[i].width) * fraction
}

road_center_sample :: proc(
	nodes: []Track_Node,
	node_position, base_x, base_y, base_z, base_heading: f32,
) -> rl.Vector3 {
	i, next_i, fraction := track_sample_indices(nodes, node_position)
	a := road_point(nodes, i, 0, base_x, base_y, base_z, base_heading)
	b := road_point(nodes, next_i, 0, base_x, base_y, base_z, base_heading)
	return {
		a.x + (b.x - a.x) * fraction,
		a.y + (b.y - a.y) * fraction,
		a.z + (b.z - a.z) * fraction,
	}
}

road_near_sample_position :: proc(
	nodes: []Track_Node,
	playhead, base_x, base_y, base_z, base_heading: f32,
) -> f32 {
	target_z := CHASE_CAMERA_Z + ROAD_CAMERA_CLEARANCE
	front_position := playhead
	for step in 1 ..= 8 {
		back_position := playhead - f32(step)
		back_center := road_center_sample(
			nodes,
			back_position,
			base_x,
			base_y,
			base_z,
			base_heading,
		)
		if back_center.z <= target_z {
			for _ in 0 ..< 12 {
				middle_position := (back_position + front_position) * 0.5
				middle_center := road_center_sample(
					nodes,
					middle_position,
					base_x,
					base_y,
					base_z,
					base_heading,
				)
				if middle_center.z <= target_z do back_position = middle_position
				else do front_position = middle_position
			}
			return front_position
		}
		front_position = back_position
	}
	return front_position
}

heading_sample :: proc(nodes: []Track_Node, node_position: f32) -> f32 {
	i, next_i, fraction := track_sample_indices(nodes, node_position)
	return nodes[i].heading + (nodes[next_i].heading - nodes[i].heading) * fraction
}

pitch_sample :: proc(nodes: []Track_Node, node_position: f32) -> f32 {
	i, next_i, fraction := track_sample_indices(nodes, node_position)
	return nodes[i].pitch + (nodes[next_i].pitch - nodes[i].pitch) * fraction
}

pace_sample :: proc(nodes: []Track_Node, node_position: f32) -> f32 {
	i, next_i, fraction := track_sample_indices(nodes, node_position)
	return nodes[i].pace + (nodes[next_i].pace - nodes[i].pace) * fraction
}

pitch_around :: proc(point: rl.Vector3, pivot_y, pitch: f32) -> rl.Vector3 {
	c := f32(math.cos(f64(pitch)))
	s := f32(math.sin(f64(pitch)))
	dy := point.y - pivot_y
	return {point.x, pivot_y + dy * c + point.z * s, point.z * c - dy * s}
}

lift_road_overlay :: proc(point: rl.Vector3, amount: f32) -> rl.Vector3 {
	result := point
	result.y += amount
	return result
}
