package main

import "core:math"

ROAD_STEP :: f32(5.5)

PICKUP :: i32(1)
HAZARD :: i32(2)
SHIELD :: i32(3)
BOOST :: i32(4)

CLIMB :: i32(0)
DROP :: i32(1)
SLALOM :: i32(2)
TUNNEL :: i32(3)

GATE :: i32(1)
ARCH :: i32(2)
PORTAL :: i32(3)
RAMP :: i32(4)

Track_Node :: struct {
	bass, mid, high:  f32,
	energy, onset:    f32,
	tempo, activity:  f32,
	pace, width:      f32,
	curve_x, curve_y: f32,
	curve_z, heading: f32,
	pitch:            f32,
	distance:         f32,
	beat:             f32,
	lane:             i32,
	kind, tone:       i32,
	section, feature: i32,
}

compose_track :: proc(nodes: []Track_Node, song_seed: u32) {
	count := len(nodes)
	// Third pass composes six-second musical movements into a true 3D centerline.
	SECTION_LENGTH :: 64
	center_x, center_y, center_z, heading, pitch, distance: f32
	section, previous_section := CLIMB, CLIMB
	section_direction: f32 = 1
	for node_i in 0 ..< count {
		node := &nodes[node_i]
		section_start := (node_i / SECTION_LENGTH) * SECTION_LENGTH
		if node_i % SECTION_LENGTH == 0 {
			previous_section = section
			end := min(count, node_i + SECTION_LENGTH)
			bass, mid, high, pace: f32
			for look in node_i ..< end {
				bass += nodes[look].bass
				mid += nodes[look].mid
				high += nodes[look].high
				pace += nodes[look].pace
			}
			n := f32(max(1, end - node_i))
			bass, mid, high, pace = bass / n, mid / n, high / n, pace / n
			if high > bass && high > mid * 0.28 do section = TUNNEL
			else if pace < 0.32 do section = CLIMB
			else if bass >= mid && bass >= high do section = DROP
			else do section = SLALOM
			if node_i == 0 {
				section_direction = 1
				if (song_seed & 1) == 0 do section_direction = -1
			} else {
				// Alternating broad turns guarantees a varied ride; slaloms and tunnels still
				// oscillate inside their movement for smaller musical bends.
				section_direction *= -1
			}
		}
		node.section = section
		phase := f32(node_i - section_start) / f32(SECTION_LENGTH)
		seed := song_seed ~ (u32(node_i) * 1664525 + 1013904223)

		node.lane = i32(seed % 3) - 1
		if section == SLALOM do node.lane = i32((node_i / 3) % 3) - 1
		if section == TUNNEL do node.lane = i32((node_i / 3) % 2) * 2 - 1
		if node.bass >= node.mid && node.bass >= node.high do node.tone = 0
		else if node.mid >= node.high do node.tone = 1
		else do node.tone = 2
		roll := int((seed >> 8) % 100)
		if node.kind == 0 && node_i > 0 && node_i % 200 == 100 {
			node.kind = SHIELD
		} else if node.kind == 0 && node_i % SECTION_LENGTH == 3 {
			node.kind = BOOST
		} else if node.kind == 0 && node.pace > 0.48 && node_i % 5 == 2 && roll < 78 {
			node.kind = HAZARD
		} else if node.kind == 0 && node_i % 3 == 0 && roll < 78 && node.mid + node.high > 0.20 {
			node.kind = PICKUP
			node.beat = 0.20 + min(0.38, node.high * 0.45)
		}

		// Pace owns both world speed and road pitch: calm music climbs; intense music dives.
		// Integrating an angle over world distance keeps fast drops steep instead of flattening
		// them merely because consecutive samples are farther apart.
		pace_curve := node.pace * node.pace * (3 - 2 * node.pace)
		heading_target: f32
		pitch_wave: f32
		switch section {
		case CLIMB:
			heading_target =
				f32(math.sin(f64(phase * math.PI))) * (0.42 + node.pace * 0.18) * section_direction
			pitch_wave = f32(math.sin(f64(phase * math.PI))) * 0.07
			node.width = 3.9
		case DROP:
			heading_target =
				f32(math.sin(f64(phase * math.PI))) * (0.54 + node.pace * 0.20) * section_direction
			pitch_wave = -f32(math.sin(f64(phase * math.PI))) * 0.10
			node.width = 4.8
		case SLALOM:
			heading_target =
				f32(math.sin(f64(phase * 4 * math.PI))) *
				(0.58 + node.mid * 0.22) *
				section_direction
			pitch_wave = f32(math.sin(f64(phase * 2 * math.PI))) * 0.11
			node.width = 4.25
		case TUNNEL:
			heading_target =
				f32(math.sin(f64(phase * 6 * math.PI))) *
				(0.50 + node.high * 0.20) *
				section_direction
			pitch_wave = f32(math.sin(f64(phase * 4 * math.PI))) * 0.13
			node.width = 4.35
		}
		pitch_target := clamp(
			0.22 - pace_curve * 0.56 - node.onset * 0.05 + pitch_wave - center_y * 0.000015,
			-0.38,
			0.30,
		)
		heading = heading * 0.80 + heading_target * 0.20
		pitch = pitch * 0.78 + pitch_target * 0.22
		step_distance := ROAD_STEP * (0.52 + pace_curve * 2.75)
		horizontal_step := f32(math.cos(f64(pitch))) * step_distance
		center_x += f32(math.sin(f64(heading))) * horizontal_step
		center_y += f32(math.sin(f64(pitch))) * step_distance
		center_z += f32(math.cos(f64(heading))) * horizontal_step
		distance += step_distance

		if node_i % SECTION_LENGTH == 0 do node.feature = PORTAL
		if section == TUNNEL && node_i % 4 == 0 do node.feature = ARCH
		if node.beat > 0.65 do node.feature = GATE
		if node_i % SECTION_LENGTH == 0 && previous_section == CLIMB && section == DROP do node.feature = RAMP
		if node_i > 0 && node.pace - nodes[node_i - 1].pace > 0.16 do node.feature = RAMP
		node.curve_x, node.curve_y, node.curve_z = center_x, center_y, center_z
		node.heading, node.pitch, node.distance = heading, pitch, distance
	}
	close_track_loop(nodes)
}
