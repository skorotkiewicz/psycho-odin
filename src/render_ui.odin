package main

import rl "vendor:raylib"

pace_hue :: proc(pace: f32) -> f32 {
	p := clamp(pace, 0, 1)
	heat := p * p * (3 - 2 * p)
	return 195 + heat * 187
}

wrap_hue :: proc(hue: f32) -> f32 {
	wrapped := hue
	for wrapped >= 360 do wrapped -= 360
	for wrapped < 0 do wrapped += 360
	return wrapped
}

pace_opposite_hue :: proc(pace: f32) -> f32 {
	return wrap_hue(pace_hue(pace) + 180)
}

pace_color :: proc(pace, value: f32, alpha: u8 = 255) -> rl.Color {
	// Cool cyan climbs travel through violet into hot gold/red descents.
	p := clamp(pace, 0, 1)
	color := rl.ColorFromHSV(pace_hue(p), 0.62 + p * 0.34, clamp(value, 0, 1))
	color.a = alpha
	return color
}

pace_opposite_color :: proc(pace, value: f32, alpha: u8 = 255) -> rl.Color {
	p := clamp(pace, 0, 1)
	color := rl.ColorFromHSV(pace_opposite_hue(p), 0.62 + p * 0.34, clamp(value, 0, 1))
	color.a = alpha
	return color
}

course_map_alpha :: proc(alpha: u8, traces_only: bool) -> u8 {
	if traces_only do return u8(u16(alpha) / 2)
	return alpha
}

course_map_point :: proc(
	nodes: []Track_Node,
	node_i: int,
	left, top, plot_width, plot_height, min_height, max_height: f32,
) -> rl.Vector2 {
	node := nodes[clamp(node_i, 0, len(nodes) - 1)]
	height_range := max(1, max_height - min_height)
	return {
		left + f32(node_i) / f32(len(nodes) - 1) * plot_width,
		top + (max_height - node.curve_y) / height_range * plot_height,
	}
}

course_plan_point :: proc(
	nodes: []Track_Node,
	node_i: int,
	left, top, plot_width, plot_height, min_x, max_x, min_z, max_z: f32,
) -> rl.Vector2 {
	node := nodes[clamp(node_i, 0, len(nodes) - 1)]
	x_range := max(1, max_x - min_x)
	z_range := max(1, max_z - min_z)
	return {
		left + (node.curve_x - min_x) / x_range * plot_width,
		top + (node.curve_z - min_z) / z_range * plot_height,
	}
}

Course_Map_Bounds :: struct {
	min_height, max_height: f32,
	min_x, max_x:           f32,
	min_z, max_z:           f32,
}

calculate_course_map_bounds :: proc(nodes: []Track_Node) -> Course_Map_Bounds {
	if len(nodes) == 0 do return {}
	bounds := Course_Map_Bounds {
		min_height = nodes[0].curve_y,
		max_height = nodes[0].curve_y,
		min_x      = nodes[0].curve_x,
		max_x      = nodes[0].curve_x,
		min_z      = nodes[0].curve_z,
		max_z      = nodes[0].curve_z,
	}
	for node in nodes {
		bounds.min_height = min(bounds.min_height, node.curve_y)
		bounds.max_height = max(bounds.max_height, node.curve_y)
		bounds.min_x, bounds.max_x =
			min(bounds.min_x, node.curve_x), max(bounds.max_x, node.curve_x)
		bounds.min_z, bounds.max_z =
			min(bounds.min_z, node.curve_z), max(bounds.max_z, node.curve_z)
	}
	return bounds
}

draw_course_map :: proc(
	nodes: []Track_Node,
	current: int,
	x, y, width, height: i32,
	bounds: Course_Map_Bounds,
	traces_only: bool = false,
) {
	if len(nodes) < 2 || width < 80 || height < 50 do return
	if !traces_only {
		rl.DrawRectangle(x, y, width, height, rl.Color{2, 5, 17, 218})
		rl.DrawRectangleLines(x, y, width, height, rl.Color{80, 135, 190, 130})
		rl.DrawText(
			"RIDE MAP  //  HEIGHT + TURNS",
			x + 11,
			y + 8,
			13,
			rl.Color{160, 205, 235, 230},
		)
	}

	left, top: f32
	total_width, plot_height: f32
	if traces_only {
		left, top = f32(x), f32(y)
		total_width, plot_height = f32(width), f32(height)
	} else {
		left, top = f32(x + 11), f32(y + 28)
		total_width, plot_height = f32(width - 22), f32(height - 39)
	}
	profile_width := total_width * 0.70
	plan_gap: f32 = 12
	plan_left := left + profile_width + plan_gap
	plan_width := total_width - profile_width - plan_gap
	if !traces_only {
		rl.DrawLine(
			i32(plan_left - plan_gap * 0.5),
			i32(top),
			i32(plan_left - plan_gap * 0.5),
			i32(top + plot_height),
			rl.Color{70, 95, 135, 105},
		)
	}
	samples_on_map := min(len(nodes), max(2, int(total_width)))
	previous_point := course_map_point(
		nodes,
		0,
		left,
		top,
		profile_width,
		plot_height,
		bounds.min_height,
		bounds.max_height,
	)
	previous_plan := course_plan_point(
		nodes,
		0,
		plan_left,
		top,
		plan_width,
		plot_height,
		bounds.min_x,
		bounds.max_x,
		bounds.min_z,
		bounds.max_z,
	)
	for sample in 1 ..< samples_on_map {
		node_i := sample * (len(nodes) - 1) / (samples_on_map - 1)
		point := course_map_point(
			nodes,
			node_i,
			left,
			top,
			profile_width,
			plot_height,
			bounds.min_height,
			bounds.max_height,
		)
		plan_point := course_plan_point(
			nodes,
			node_i,
			plan_left,
			top,
			plan_width,
			plot_height,
			bounds.min_x,
			bounds.max_x,
			bounds.min_z,
			bounds.max_z,
		)
		alpha: u8 = 215
		if node_i < current do alpha = 105
		alpha = course_map_alpha(alpha, traces_only)
		color := pace_color(nodes[node_i].pace, 0.72 + nodes[node_i].pace * 0.25, alpha)
		rl.DrawLineEx(previous_point, point, 2.0, color)
		rl.DrawLineEx(previous_plan, plan_point, 2.0, color)
		previous_point = point
		previous_plan = plan_point
	}

	marker := course_map_point(
		nodes,
		current,
		left,
		top,
		profile_width,
		plot_height,
		bounds.min_height,
		bounds.max_height,
	)
	marker_alpha := course_map_alpha(255, traces_only)
	rl.DrawCircleV(marker, 5.5, rl.Color{2, 5, 17, marker_alpha})
	rl.DrawCircleLines(i32(marker.x), i32(marker.y), 6, rl.Color{255, 255, 255, marker_alpha})
	rl.DrawCircleV(marker, 2.2, pace_color(nodes[current].pace, 1, marker_alpha))
	plan_marker := course_plan_point(
		nodes,
		current,
		plan_left,
		top,
		plan_width,
		plot_height,
		bounds.min_x,
		bounds.max_x,
		bounds.min_z,
		bounds.max_z,
	)
	rl.DrawCircleV(plan_marker, 4.5, rl.Color{2, 5, 17, marker_alpha})
	rl.DrawCircleLines(
		i32(plan_marker.x),
		i32(plan_marker.y),
		5,
		rl.Color{255, 255, 255, marker_alpha},
	)
	rl.DrawCircleV(plan_marker, 1.8, pace_color(nodes[current].pace, 1, marker_alpha))
}
