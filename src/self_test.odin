package main

import "core:fmt"
import "core:math"
import "core:strings"

self_test :: proc() {
	rate := 8000
	samples := make([]f32, rate * 24)
	defer delete(samples)
	for i in 0 ..< len(samples) {
		t := f64(i) / f64(rate)
		segment := i / (rate * 6)
		frequencies := [4]f64{100, 80, 800, 3000}
		amplitudes := [4]f32{0.02, 0.32, 0.24, 0.20}
		samples[i] = f32(math.sin(2 * math.PI * frequencies[segment] * t)) * amplitudes[segment]
		if segment > 0 && i % (rate / 2) < rate / 50 do samples[i] *= 1.8
	}
	nodes := analyze_samples(raw_data(samples), len(samples), rate, 1)
	defer delete(nodes)
	assert(len(nodes) == 240)
	assert(nodes[10].bass >= 0 && nodes[10].bass <= 1)
	assert(nodes[90].distance - nodes[89].distance > nodes[20].distance - nodes[19].distance)
	first, last := nodes[0], nodes[len(nodes) - 1]
	closure_dx := last.curve_x - first.curve_x
	closure_dy := last.curve_y - first.curve_y
	closure_dz := last.curve_z - first.curve_z
	closure_distance := f32(
		math.sqrt(
			f64(closure_dx * closure_dx + closure_dy * closure_dy + closure_dz * closure_dz),
		),
	)
	seam_heading_error := abs(wrapped_angle_delta(nodes[len(nodes) - 2].heading, first.heading))
	seam_pitch_error := abs(nodes[len(nodes) - 2].pitch - first.pitch)
	seam_bank_error := abs(road_bank(nodes, len(nodes) - 1) - road_bank(nodes, 0))
	fmt.printfln(
		"self-test: loop closure %.3f; seam heading %.2f° pitch %.2f° bank %.2f°",
		closure_distance,
		f64(seam_heading_error) * 180 / math.PI,
		f64(seam_pitch_error) * 180 / math.PI,
		f64(seam_bank_error) * 180 / math.PI,
	)
	assert(closure_distance < 0.01, "the final cached road point must return to the start")
	assert(
		seam_heading_error < 0.04 && seam_pitch_error < 0.04,
		"the loop seam must preserve its tangent",
	)
	assert(seam_bank_error < 0.08, "the loop seam must preserve road banking")
	assert(abs(last.width - first.width) < 0.001, "the loop seam must preserve road width")
	pickups, hazards, features: int
	sections: bit_set[0 ..< 4]
	for node in nodes {
		if node.kind == PICKUP do pickups += 1
		if node.kind == HAZARD do hazards += 1
		if node.feature != 0 do features += 1
		sections += {int(node.section)}
	}
	min_x, max_x := nodes[0].curve_x, nodes[0].curve_x
	min_y, max_y := nodes[0].curve_y, nodes[0].curve_y
	min_turn, max_turn, min_pitch, max_pitch: f32
	for node in nodes {
		min_x, max_x = min(min_x, node.curve_x), max(max_x, node.curve_x)
		min_y, max_y = min(min_y, node.curve_y), max(max_y, node.curve_y)
	}
	for i in 0 ..< len(nodes) - 1 {
		dx := nodes[i + 1].curve_x - nodes[i].curve_x
		dy := nodes[i + 1].curve_y - nodes[i].curve_y
		dz := nodes[i + 1].curve_z - nodes[i].curve_z
		heading := f32(math.atan2(f64(dx), f64(dz)))
		planar_step := f32(math.sqrt(f64(dx * dx + dz * dz)))
		pitch := f32(math.atan2(f64(dy), f64(max(0.001, planar_step))))
		spatial_step := f32(math.sqrt(f64(dx * dx + dy * dy + dz * dz)))
		arc_step := nodes[i + 1].distance - nodes[i].distance
		assert(spatial_step > 0.01, "closed centerline segments must not collapse")
		assert(
			abs(spatial_step - arc_step) < 0.01,
			"cached distance must match 3D centerline arc length",
		)
		assert(
			abs(wrapped_angle_delta(heading, nodes[i].heading)) < 0.001,
			"cached heading must match centerline tangent",
		)
		assert(abs(pitch - nodes[i].pitch) < 0.001, "cached pitch must match centerline tangent")
		if i > 0 {
			turn := nodes[i].heading - nodes[i - 1].heading
			min_turn = min(min_turn, turn)
			max_turn = max(max_turn, turn)
		}
		min_pitch = min(min_pitch, pitch)
		max_pitch = max(max_pitch, pitch)
	}
	fmt.printfln(
		"self-test: local turn %.1f° left / %.1f° right; pitch %.1f° up / %.1f° down",
		f64(max_turn) * 180 / math.PI,
		f64(min_turn) * 180 / math.PI,
		f64(max_pitch) * 180 / math.PI,
		f64(min_pitch) * 180 / math.PI,
	)
	assert(pickups > 0 && hazards > 0)
	assert(card(sections) == 4)
	assert(max_x - min_x > 16 && max_y - min_y > 18 && features > 4)
	assert(max_turn > 0.004 && min_turn < -0.004, "closed road must curve both ways")
	assert(max_pitch > 0.10 && min_pitch < -0.10, "road must make visible climbs and drops")
	probe_i := len(nodes) / 2
	probe := nodes[probe_i]
	probe_left := road_point(
		nodes,
		probe_i,
		-probe.width,
		probe.curve_x,
		probe.curve_y,
		probe.curve_z,
		probe.heading,
	)
	probe_right := road_point(
		nodes,
		probe_i,
		probe.width,
		probe.curve_x,
		probe.curve_y,
		probe.curve_z,
		probe.heading,
	)
	assert(abs(probe_left.x + probe.width) < 0.01 && abs(probe_left.z) < 0.01)
	assert(abs(probe_right.x - probe.width) < 0.01 && abs(probe_right.z) < 0.01)
	future_i := min(len(nodes) - 1, probe_i + 10)
	future_center := road_point(
		nodes,
		future_i,
		0,
		probe.curve_x,
		probe.curve_y,
		probe.curve_z,
		probe.heading,
	)
	assert(
		future_center.z > 1,
		"future cached centerline must remain ahead in the local tangent frame",
	)
	assert(abs(future_center.x) > 0.1, "future tangent transform must expose the upcoming bend")
	worst_uncropped_z, worst_cropped_z: f32 = 1e9, 1e9
	shallowest_cropped_z: f32 = -1e9
	worst_near_i := 0
	near_test_fractions := [5]f32{0, 0.2, 0.5, 0.8, 0.95}
	for i in 0 ..< len(nodes) - 1 {
		for fraction in near_test_fractions {
			base_x := nodes[i].curve_x + (nodes[i + 1].curve_x - nodes[i].curve_x) * fraction
			base_y := nodes[i].curve_y + (nodes[i + 1].curve_y - nodes[i].curve_y) * fraction
			base_z := nodes[i].curve_z + (nodes[i + 1].curve_z - nodes[i].curve_z) * fraction
			base_heading := nodes[i].heading + (nodes[i + 1].heading - nodes[i].heading) * fraction
			uncropped_center := road_point(nodes, i, 0, base_x, base_y, base_z, base_heading)
			playhead := f32(i) + fraction
			sample_position := road_near_sample_position(
				nodes,
				playhead,
				base_x,
				base_y,
				base_z,
				base_heading,
			)
			sample_width := width_sample(nodes, sample_position)
			cropped_center := road_point_sample(
				nodes,
				sample_position,
				0,
				base_x,
				base_y,
				base_z,
				base_heading,
			)
			cropped_left := road_point_sample(
				nodes,
				sample_position,
				-sample_width,
				base_x,
				base_y,
				base_z,
				base_heading,
			)
			cropped_right := road_point_sample(
				nodes,
				sample_position,
				sample_width,
				base_x,
				base_y,
				base_z,
				base_heading,
			)
			if uncropped_center.z < worst_uncropped_z {
				worst_uncropped_z = uncropped_center.z
				worst_near_i = i
			}
			worst_cropped_z = min(worst_cropped_z, cropped_left.z, cropped_right.z)
			shallowest_cropped_z = max(shallowest_cropped_z, cropped_center.z)
		}
	}
	fmt.printfln(
		"self-test: near-road clip old %.2f at slice %d; edge %.2f shallow %.2f; camera %.2f",
		worst_uncropped_z,
		worst_near_i,
		worst_cropped_z,
		shallowest_cropped_z,
		CHASE_CAMERA_Z,
	)
	assert(worst_uncropped_z < CHASE_CAMERA_Z, "the regression fixture must cross the camera")
	assert(
		worst_cropped_z > CHASE_CAMERA_Z + 1,
		"the first visible road edge must stay safely ahead of the camera",
	)
	assert(
		shallowest_cropped_z < -3,
		"the first visible road edge must extend behind the player and fill the foreground",
	)
	sample_boundary := f32(probe_i + 10)
	preview_before := road_center_sample(
		nodes,
		sample_boundary + 0.999,
		probe.curve_x,
		probe.curve_y,
		probe.curve_z,
		probe.heading,
	)
	preview_after := road_center_sample(
		nodes,
		sample_boundary + 1.001,
		probe.curve_x,
		probe.curve_y,
		probe.curve_z,
		probe.heading,
	)
	preview_dx := preview_after.x - preview_before.x
	preview_dy := preview_after.y - preview_before.y
	preview_dz := preview_after.z - preview_before.z
	preview_jump := f32(
		math.sqrt(
			f64(preview_dx * preview_dx + preview_dy * preview_dy + preview_dz * preview_dz),
		),
	)
	fmt.printfln("self-test: camera preview cache-boundary jump %.3f", preview_jump)
	assert(preview_jump < 0.10, "camera preview must move continuously across cached audio slices")
	loop_span := f32(len(nodes) - 1)
	seam_preview_before := road_center_sample(
		nodes,
		loop_span - 0.001,
		first.curve_x,
		first.curve_y,
		first.curve_z,
		first.heading,
	)
	seam_preview_after := road_center_sample(
		nodes,
		loop_span + 0.001,
		first.curve_x,
		first.curve_y,
		first.curve_z,
		first.heading,
	)
	seam_preview_dx := seam_preview_after.x - seam_preview_before.x
	seam_preview_dy := seam_preview_after.y - seam_preview_before.y
	seam_preview_dz := seam_preview_after.z - seam_preview_before.z
	seam_preview_jump := f32(
		math.sqrt(
			f64(
				seam_preview_dx * seam_preview_dx +
				seam_preview_dy * seam_preview_dy +
				seam_preview_dz * seam_preview_dz,
			),
		),
	)
	fmt.printfln("self-test: camera loop-seam jump %.3f", seam_preview_jump)
	assert(seam_preview_jump < 0.10, "camera preview must continue through the loop seam")
	assert(abs(lane_position(4.8, 1) - 3.2) < 0.001)
	assert(steer_input(true, false) > 0, "A/left must move toward screen-left for a +Z camera")
	assert(mouse_lane_target(0, 1000) > 0.99)
	assert(abs(mouse_lane_target(500, 1000)) < 0.001)
	assert(mouse_lane_target(1000, 1000) < -0.99)
	mouse_step := smooth_mouse_lane(0, 1, 1.0 / 60.0)
	assert(
		mouse_step > 0.32 && mouse_step < 1,
		"default mouse response must be quicker than the alpha build",
	)
	assert(!ride_finished(false, false, false), "a ride cannot finish before playback starts")
	assert(!ride_finished(true, true, false), "pausing must not finish a ride")
	assert(
		ride_finished(false, true, false),
		"stopped playback must finish even if the final sample was skipped",
	)
	config_test := parse_game_config(
		`
mouse_response = 31.0
hide_cursor = false
music_volume = 2.0 # must clamp
visual_fx = false
audio_fx_strength = 0.33
`,
	)
	assert(abs(config_test.mouse_response - 31) < 0.001)
	assert(!config_test.hide_cursor && !config_test.visual_fx)
	assert(abs(config_test.music_volume - 0.8) < 0.001)
	assert(abs(config_test.audio_fx_strength - 0.33) < 0.001)
	result_test := format_game_result(123, "music/test.wav", 4567, 12, 3, 98.5)
	assert(strings.contains(result_test, "\t4567\t12\t3\t98.50"))
	delete(result_test)

	// Multi-second musical dynamics must produce opposite grades and visibly different speeds.
	rhythm_samples := make([]f32, rate * 24)
	defer delete(rhythm_samples)
	for i in 0 ..< len(rhythm_samples) {
		t := f64(i) / f64(rate)
		amplitude: f32 = 0.025
		if (i / (rate * 6)) % 2 == 1 do amplitude = 0.30
		rhythm_samples[i] = f32(math.sin(2 * math.PI * 100 * t)) * amplitude
	}
	rhythm := analyze_samples(raw_data(rhythm_samples), len(rhythm_samples), rate, 1)
	defer delete(rhythm)
	quiet_slope, loud_slope, quiet_speed, loud_speed: f32
	quiet_count, loud_count: int
	for i in 1 ..< len(rhythm) {
		if i % 60 < 20 || i % 60 > 56 do continue
		slope := rhythm[i].curve_y - rhythm[i - 1].curve_y
		speed := rhythm[i].distance - rhythm[i - 1].distance
		if (i / 60) % 2 == 0 {
			quiet_slope += slope
			quiet_speed += speed
			quiet_count += 1
		} else {
			loud_slope += slope
			loud_speed += speed
			loud_count += 1
		}
	}
	quiet_slope, loud_slope = quiet_slope / f32(quiet_count), loud_slope / f32(loud_count)
	quiet_speed, loud_speed = quiet_speed / f32(quiet_count), loud_speed / f32(loud_count)
	fmt.printfln(
		"self-test: quiet grade %.3f speed %.2f | loud grade %.3f speed %.2f",
		quiet_slope,
		quiet_speed,
		loud_slope,
		loud_speed,
	)
	quiet_run := f32(
		math.sqrt(f64(max(0.001, quiet_speed * quiet_speed - quiet_slope * quiet_slope))),
	)
	loud_run := f32(math.sqrt(f64(max(0.001, loud_speed * loud_speed - loud_slope * loud_slope))))
	quiet_angle := f32(math.atan2(f64(quiet_slope), f64(quiet_run)))
	loud_angle := f32(math.atan2(f64(loud_slope), f64(loud_run)))
	fmt.printfln(
		"self-test: actual road pitch %.1f° quiet / %.1f° loud",
		f64(quiet_angle) * 180 / math.PI,
		f64(loud_angle) * 180 / math.PI,
	)
	assert(quiet_slope > 0.12 && loud_slope < -0.12)
	assert(loud_speed > quiet_speed * 1.8)
	assert(
		quiet_angle > 0.10 && loud_angle < -0.10,
		"climbs and drops must remain visible at speed",
	)

	// Beat periodicity affects pace even when the average amplitude stays similar.
	tempo_samples := make([]f32, rate * 28)
	defer delete(tempo_samples)
	for i in 0 ..< len(tempo_samples) {
		t := f64(i) / f64(rate)
		period := rate * 4 / 5 // 75 BPM
		if i >= rate * 14 do period = rate * 2 / 5 // 150 BPM
		pulse_length := rate / 18
		phase := i % period
		envelope: f32
		if phase < pulse_length do envelope = 1 - f32(phase) / f32(pulse_length)
		tempo_samples[i] =
			f32(math.sin(2 * math.PI * 105 * t)) * (0.035 + envelope * 0.31) +
			f32(math.sin(2 * math.PI * 1450 * t)) * envelope * 0.06
	}
	tempo_nodes := analyze_samples(raw_data(tempo_samples), len(tempo_samples), rate, 1)
	defer delete(tempo_nodes)
	slow_tempo, fast_tempo, slow_pace, fast_pace: f32
	metric_count: int
	for i in 40 ..< 105 {
		slow_tempo += tempo_nodes[i].tempo
		slow_pace += tempo_nodes[i].pace
		fast_tempo += tempo_nodes[i + 140].tempo
		fast_pace += tempo_nodes[i + 140].pace
		metric_count += 1
	}
	slow_tempo, fast_tempo = slow_tempo / f32(metric_count), fast_tempo / f32(metric_count)
	slow_pace, fast_pace = slow_pace / f32(metric_count), fast_pace / f32(metric_count)
	fmt.printfln(
		"self-test: slow beat %.2f pace %.2f | fast beat %.2f pace %.2f",
		slow_tempo,
		slow_pace,
		fast_tempo,
		fast_pace,
	)
	assert(fast_tempo > slow_tempo + 0.12)
	assert(fast_pace > slow_pace + 0.05)

	path := ".psycho_cache/self-test.map"
	assert(save_map(path, nodes))
	loaded, ok := load_map(path)
	defer delete(loaded)
	assert(ok && len(loaded) == len(nodes) && loaded[0].lane == nodes[0].lane)
	assert(
		loaded[0].curve_z == nodes[0].curve_z &&
		loaded[0].heading == nodes[0].heading &&
		loaded[0].pitch == nodes[0].pitch,
	)
	assert(loaded[len(loaded) - 1].curve_z == nodes[len(nodes) - 1].curve_z)
	fmt.println("self-test: ok")
}
