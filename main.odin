package main

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

MAP_MAGIC :: u64(0x50535943484f3031) // PSYCHO01
MAP_VERSION :: u32(5)
STEP :: f32(0.10)
ROAD_STEP :: f32(5.5)
LANE_WIDTH :: f32(2.6)

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

Track_Node :: struct {
	bass, mid, high:  f32,
	energy, onset:    f32,
	pace, width:      f32,
	curve_x, curve_y: f32,
	distance:         f32,
	beat:             f32,
	lane:             i32,
	kind, tone:       i32,
	section, feature: i32,
}

Cache_Header :: struct {
	magic:          u64,
	version, count: u32,
}

// Audio-thread state. The effect is optional because binaural/ASMR responses vary by listener.
fx_on: bool
fx_amount: f32 = 0.22
fx_beat_hz: f64 = 7
fx_tingle: f32
fx_rate: f64 = 48000
fx_channels: int = 2
fx_phase_l, fx_phase_r, fx_pan_phase: f64
fx_noise: u32 = 0x91e10da5
fx_soft_noise: f32
fx_delay: [4096][2]f32
fx_delay_at: int

audio_fx :: proc "c" (buffer_data: rawptr, frames: u32) {
	if !fx_on || fx_channels < 2 do return
	samples := cast([^]f32)buffer_data
	tau := 2.0 * math.PI
	for frame in 0 ..< int(frames) {
		fx_phase_l += tau * 180.0 / fx_rate
		fx_phase_r += tau * (180.0 + fx_beat_hz) / fx_rate
		fx_pan_phase += tau * 0.13 / fx_rate
		if fx_phase_l > tau do fx_phase_l -= tau
		if fx_phase_r > tau do fx_phase_r -= tau
		if fx_pan_phase > tau do fx_pan_phase -= tau

		fx_noise ~= fx_noise << 13
		fx_noise ~= fx_noise >> 17
		fx_noise ~= fx_noise << 5
		white := f32(fx_noise & 0xffff) / 32767.5 - 1.0
		fx_soft_noise += (white - fx_soft_noise) * 0.035
		breath := fx_soft_noise * (0.002 + fx_tingle * 0.004)
		pan := f32(math.sin(fx_pan_phase))
		tone := fx_amount * 0.025
		dry_l := samples[frame * fx_channels]
		dry_r := samples[frame * fx_channels + 1]
		delayed := (fx_delay_at + len(fx_delay) - 840) % len(fx_delay)
		width := fx_amount * 0.055
		left :=
			dry_l +
			f32(math.sin(fx_phase_l)) * tone +
			breath * (1 - pan) +
			fx_delay[delayed][1] * width
		right :=
			dry_r +
			f32(math.sin(fx_phase_r)) * tone +
			breath * (1 + pan) +
			fx_delay[delayed][0] * width
		fx_delay[fx_delay_at] = {dry_l, dry_r}
		fx_delay_at = (fx_delay_at + 1) % len(fx_delay)
		samples[frame * fx_channels] = clamp(left, -1, 1)
		samples[frame * fx_channels + 1] = clamp(right, -1, 1)
	}
}

cache_path :: proc(file_bytes: []byte) -> string {
	return fmt.aprintf(".psycho_cache/%016x.map", hash.fnv64a(file_bytes, u64(MAP_VERSION)))
}

save_map :: proc(path: string, nodes: []Track_Node) -> bool {
	if err := os.make_directory_all(".psycho_cache"); err != nil && err != .Exist do return false
	header := Cache_Header{MAP_MAGIC, MAP_VERSION, u32(len(nodes))}
	data := make([]byte, size_of(Cache_Header) + len(nodes) * size_of(Track_Node))
	defer delete(data)
	n := copy(data, mem.ptr_to_bytes(&header))
	copy(data[n:], mem.slice_to_bytes(nodes))
	return os.write_entire_file(path, data) == nil
}

load_map :: proc(path: string) -> (nodes: []Track_Node, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	defer delete(data)
	if len(data) < size_of(Cache_Header) do return

	header: Cache_Header
	copy(mem.ptr_to_bytes(&header), data[:size_of(Cache_Header)])
	if header.magic != MAP_MAGIC || header.version != MAP_VERSION || header.count == 0 do return
	want := size_of(Cache_Header) + int(header.count) * size_of(Track_Node)
	if want != len(data) || header.count > 10_000_000 do return

	nodes = make([]Track_Node, int(header.count))
	copy(mem.slice_to_bytes(nodes), data[size_of(Cache_Header):])
	return nodes, true
}

analyze_samples :: proc(samples: [^]f32, frame_count, sample_rate, channels: int) -> []Track_Node {
	frames_per_node := max(1, int(f32(sample_rate) * STEP))
	count := max(1, (frame_count + frames_per_node - 1) / frames_per_node)
	nodes := make([]Track_Node, count)
	low, body: f32
	low_alpha := f32(1 - math.exp(-2 * math.PI * 180 / f64(sample_rate)))
	body_alpha := f32(1 - math.exp(-2 * math.PI * 2400 / f64(sample_rate)))
	mean_energy: f32
	song_seed: u32 = 2166136261

	// First pass: inexpensive three-band filter bank. It is plenty for level generation;
	// ponytail: replace with an FFT only if profiling/playtests show missing musical detail.
	for node_i in 0 ..< count {
		start := node_i * frames_per_node
		finish := min(frame_count, start + frames_per_node)
		bass_sum, mid_sum, high_sum: f64
		for frame in start ..< finish {
			sample: f32
			for channel in 0 ..< channels do sample += samples[frame * channels + channel]
			sample /= f32(channels)
			low += low_alpha * (sample - low)
			body += body_alpha * (sample - body)
			mid := body - low
			high := sample - body
			bass_sum += f64(low * low)
			mid_sum += f64(mid * mid)
			high_sum += f64(high * high)
		}
		n := f64(max(1, finish - start))
		bass := f32(math.sqrt(bass_sum / n))
		mid := f32(math.sqrt(mid_sum / n))
		high := f32(math.sqrt(high_sum / n))
		nodes[node_i].bass, nodes[node_i].mid, nodes[node_i].high = bass, mid, high
		mean_energy += bass * 0.9 + mid * 0.65 + high * 0.35
		song_seed = (song_seed ~ u32((bass * 997 + mid * 619 + high * 389) * 1_000_000)) * 16777619
	}
	mean_energy = max(mean_energy / f32(count), 0.0001)

	// Second pass normalizes dynamics against the whole song so quiet and loud masters play alike.
	for node_i in 0 ..< count {
		node := &nodes[node_i]
		raw_energy := node.bass * 0.9 + node.mid * 0.65 + node.high * 0.35
		intensity := clamp(raw_energy / (mean_energy * 2.15), 0, 1)
		band_scale := 1 / (mean_energy * 2.4)
		node.bass = clamp(node.bass * band_scale, 0, 1)
		node.mid = clamp(node.mid * band_scale, 0, 1)
		node.high = clamp(node.high * band_scale, 0, 1)
		node.energy = intensity
	}

	// Onsets provide the rhythmic half of pace; loudness alone cannot distinguish busy from sustained music.
	flux_average, prior_bass, prior_mid: f32
	last_beat := -10
	for node_i in 0 ..< count {
		node := &nodes[node_i]
		flux :=
			max(0, node.bass - prior_bass) * 0.75 +
			max(0, node.mid - prior_mid) * 0.4 +
			max(0, node.high - nodes[max(0, node_i - 1)].high) * 0.2
		flux_average = flux_average * 0.9 + flux * 0.1
		node.onset = clamp(flux * 2.8, 0, 1)
		if node_i > 8 && node_i - last_beat > 2 && flux > max(0.045, flux_average * 1.65) {
			node.beat = clamp(flux * 2.8, 0.3, 1)
			node.kind = PICKUP
			last_beat = node_i
		}
		prior_bass, prior_mid = node.bass, node.mid
	}

	// Offline look-around makes a crest arrive with a drop instead of lagging behind it.
	for node_i in 0 ..< count {
		energy, activity, weight_sum: f32
		for look := max(0, node_i - 3); look <= min(count - 1, node_i + 3); look += 1 {
			weight := f32(4 - abs(look - node_i))
			energy += nodes[look].energy * weight
			activity += nodes[look].onset * weight
			weight_sum += weight
		}
		energy /= weight_sum
		activity = clamp(activity / weight_sum * 3.2, 0, 1)
		texture := clamp(nodes[node_i].mid + nodes[node_i].high, 0, 1)
		nodes[node_i].pace = clamp(energy * 0.72 + activity * 0.22 + texture * 0.06, 0, 1)
	}

	// Third pass composes six-second musical movements instead of one generic wobble.
	SECTION_LENGTH :: 64
	height, slope, curve, turn, distance: f32
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
			section_direction = 1
			if ((song_seed ~ (u32(node_i / SECTION_LENGTH) * 747796405 + 2891336453)) & 1) == 0 do section_direction = -1
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

		// Pace alone owns grade and distance: calm music climbs slowly, busy music dives quickly.
		base_slope := (0.46 - node.pace) * 0.78 - node.onset * 0.06 - height * 0.00018
		turn_target: f32
		switch section {
		case CLIMB:
			turn_target =
				f32(math.sin(f64(phase * math.PI))) * (0.08 + node.pace * 0.12) * section_direction
			node.width = 3.9
		case DROP:
			turn_target = (0.14 + node.pace * 0.18) * section_direction
			node.width = 4.8
		case SLALOM:
			turn_target =
				f32(math.sin(f64(phase * 4 * math.PI + f32(song_seed & 255) * 0.01))) *
				(0.48 + node.mid * 0.42)
			node.width = 4.25
		case TUNNEL:
			turn_target =
				f32(math.sin(f64(phase * 6 * math.PI))) *
				(0.40 + node.high * 0.38) *
				section_direction
			node.width = 4.35
		}
		slope = slope * 0.55 + base_slope * 0.45
		height += slope
		turn = turn * 0.70 + turn_target * 0.30 - curve * 0.0012
		curve += turn
		if abs(curve) > 30 {
			curve = clamp(curve, -30, 30)
			turn *= -0.55
		}
		distance += ROAD_STEP * (0.38 + node.pace * 2.0)

		if node_i % SECTION_LENGTH == 0 do node.feature = PORTAL
		if section == TUNNEL && node_i % 4 == 0 do node.feature = ARCH
		if node.beat > 0.65 do node.feature = GATE
		if node_i % SECTION_LENGTH == 0 && previous_section == CLIMB && section == DROP do node.feature = RAMP
		if node_i > 0 && node.pace - nodes[node_i - 1].pace > 0.16 do node.feature = RAMP
		node.curve_x, node.curve_y, node.distance = curve, height, distance
	}
	return nodes
}

analyze_file :: proc(path: cstring) -> []Track_Node {
	wave := rl.LoadWave(path)
	if !rl.IsWaveValid(wave) do return nil
	defer rl.UnloadWave(wave)
	samples := rl.LoadWaveSamples(wave)
	if samples == nil do return nil
	defer rl.UnloadWaveSamples(samples)
	return analyze_samples(samples, int(wave.frameCount), int(wave.sampleRate), int(wave.channels))
}

steer_input :: proc(left, right: bool) -> f32 {
	direction: f32
	if left do direction += 1
	if right do direction -= 1
	return direction
}

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
	for node in nodes {
		min_x, max_x = min(min_x, node.curve_x), max(max_x, node.curve_x)
		min_y, max_y = min(min_y, node.curve_y), max(max_y, node.curve_y)
	}
	assert(pickups > 0 && hazards > 0)
	assert(card(sections) == 4)
	assert(max_x - min_x > 16 && max_y - min_y > 18 && features > 4)
	assert(steer_input(true, false) > 0, "A/left must move toward screen-left for a +Z camera")

	// One-second dynamics must shape the road even inside the same visual movement.
	rhythm_samples := make([]f32, rate * 12)
	defer delete(rhythm_samples)
	for i in 0 ..< len(rhythm_samples) {
		t := f64(i) / f64(rate)
		amplitude: f32 = 0.025
		if (i / rate) % 2 == 1 do amplitude = 0.30
		rhythm_samples[i] = f32(math.sin(2 * math.PI * 100 * t)) * amplitude
	}
	rhythm := analyze_samples(raw_data(rhythm_samples), len(rhythm_samples), rate, 1)
	defer delete(rhythm)
	quiet_slope, loud_slope, quiet_speed, loud_speed: f32
	quiet_count, loud_count: int
	for i in 1 ..< len(rhythm) {
		if i % 10 < 4 do continue
		slope := rhythm[i].curve_y - rhythm[i - 1].curve_y
		speed := rhythm[i].distance - rhythm[i - 1].distance
		if (i / 10) % 2 == 0 {
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
	assert(quiet_slope > 0.08 && loud_slope < -0.08)
	assert(loud_speed > quiet_speed * 1.8)

	path := ".psycho_cache/self-test.map"
	assert(save_map(path, nodes))
	loaded, ok := load_map(path)
	defer delete(loaded)
	assert(ok && len(loaded) == len(nodes) && loaded[0].lane == nodes[0].lane)
	fmt.println("self-test: ok")
}

road_point :: proc(
	nodes: []Track_Node,
	i: int,
	offset, base_x, base_y, base_distance: f32,
) -> rl.Vector3 {
	previous := nodes[max(0, i - 1)]
	next := nodes[min(len(nodes) - 1, i + 1)]
	bank := clamp((next.curve_x - previous.curve_x) * 0.52, -0.72, 0.72)
	return {
		nodes[i].curve_x - base_x + offset,
		nodes[i].curve_y - base_y - offset * bank,
		nodes[i].distance - base_distance,
	}
}

draw_ride :: proc(nodes: []Track_Node, current: int, fraction, player_lane, pulse, shake: f32) {
	next_i := min(current + 1, len(nodes) - 1)
	base_x := nodes[current].curve_x + (nodes[next_i].curve_x - nodes[current].curve_x) * fraction
	base_y := nodes[current].curve_y + (nodes[next_i].curve_y - nodes[current].curve_y) * fraction
	base_distance :=
		nodes[current].distance + (nodes[next_i].distance - nodes[current].distance) * fraction
	shake_x := f32(math.sin(rl.GetTime() * 61)) * shake * 0.24
	shake_y := f32(math.sin(rl.GetTime() * 47)) * shake * 0.18
	look := road_point(nodes, min(current + 12, len(nodes) - 1), 0, base_x, base_y, base_distance)
	previous := nodes[max(0, current - 1)]
	next := nodes[min(len(nodes) - 1, current + 1)]
	camera_bank := clamp((next.curve_x - previous.curve_x) * 0.09, -0.22, 0.22)
	camera := rl.Camera3D {
		position   = {player_lane * LANE_WIDTH * 0.3 + shake_x, 3.0 + shake_y, -8.8},
		target     = {look.x * 0.20, look.y * 0.32 + 0.15, max(28, look.z)},
		up         = {-camera_bank, 1, 0},
		fovy       = 70 + nodes[current].pace * 14,
		projection = .PERSPECTIVE,
	}
	rl.BeginMode3D(camera)

	for i := current; i < min(len(nodes) - 1, current + 86); i += 1 {
		node := nodes[i]
		left := road_point(nodes, i, -node.width, base_x, base_y, base_distance)
		right := road_point(nodes, i, node.width, base_x, base_y, base_distance)
		next_left := road_point(nodes, i + 1, -nodes[i + 1].width, base_x, base_y, base_distance)
		next_right := road_point(nodes, i + 1, nodes[i + 1].width, base_x, base_y, base_distance)
		center := road_point(nodes, i, 0, base_x, base_y, base_distance)
		section_hues := [4]f32{205, 8, 292, 155}
		hue := section_hues[clamp(node.section, 0, 3)] + f32((i * 2) % 55)
		color := rl.ColorFromHSV(hue + 190, 0.74, 0.25 + node.mid * 0.62)
		color.a = 205
		rl.DrawTriangle3D(left, next_left, right, color)
		rl.DrawTriangle3D(right, next_left, next_right, color)

		if i % 2 == 0 {
			rl.DrawLine3D(left, right, rl.Color{90, 150, 240, 155})
		}
		rl.DrawLine3D(left, next_left, rl.Color{70, 210, 255, 230})
		rl.DrawLine3D(right, next_right, rl.Color{255, 70, 205, 230})
		for lane_mark in -1 ..= 1 {
			if lane_mark == 0 do continue
			mark := f32(lane_mark) * LANE_WIDTH * 0.5
			p0 := road_point(nodes, i, mark, base_x, base_y, base_distance)
			p1 := road_point(nodes, i + 1, mark, base_x, base_y, base_distance)
			rl.DrawLine3D(p0, p1, rl.Color{100, 110, 165, 110})
		}

		if node.kind != 0 && i > current + 1 {
			object := road_point(
				nodes,
				i,
				f32(node.lane) * LANE_WIDTH,
				base_x,
				base_y,
				base_distance,
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

		if node.feature != 0 {
			tl, tr := left, right
			height: f32 = 5.6
			feature_color := rl.Color{220, 120, 255, 155}
			if node.feature == ARCH {
				height = 4.8
				feature_color = rl.Color{55, 255, 190, 125}
			} else if node.feature == PORTAL || node.feature == RAMP {
				height = 7.2
				feature_color = rl.Color{255, 210, 55, 200}
			}
			tl.y += height
			tr.y += height
			rl.DrawLine3D(left, tl, feature_color)
			rl.DrawLine3D(right, tr, feature_color)
			rl.DrawLine3D(tl, tr, feature_color)
			if node.feature == PORTAL || node.feature == RAMP {
				rl.DrawLine3D(left, tr, rl.Color{255, 80, 210, 120})
				rl.DrawLine3D(right, tl, rl.Color{70, 220, 255, 120})
			}
		}
		if node.section == DROP && i % 7 == 0 {
			rl.DrawCube(
				{left.x - 2.5, left.y - 3.5, center.z},
				1.2,
				7,
				1.2,
				rl.Color{120, 25, 35, 150},
			)
			rl.DrawCube(
				{right.x + 2.5, right.y - 3.5, center.z},
				1.2,
				7,
				1.2,
				rl.Color{120, 25, 35, 150},
			)
		}
		if i % 5 == 0 {
			star_x := f32(((i * 73) % 31) - 15) * 1.6
			star_y := f32(((i * 47) % 17) - 3) * 1.2
			rl.DrawSphere({star_x, star_y, center.z}, 0.035 + node.high * 0.08, color)
		}
	}

	ship_x := player_lane * LANE_WIDTH
	ship_color := rl.ColorFromHSV(315 + pulse * 30, 0.65, 1)
	for trail in 1 ..= 9 {
		alpha := u8(100 / trail)
		rl.DrawSphere(
			{ship_x, 0.25, -f32(trail) * 0.52},
			0.22 / f32(trail) + 0.04,
			rl.Color{60, 210, 255, alpha},
		)
	}
	rl.DrawCylinderEx({ship_x, 0.25, -0.3}, {ship_x, 0.25, 1.6}, 0.38, 0.06, 8, ship_color)
	rl.DrawTriangle3D(
		{ship_x, 0.2, 0.8},
		{ship_x - 0.95, 0.12, -0.2},
		{ship_x, 0.2, 0.05},
		ship_color,
	)
	rl.DrawTriangle3D(
		{ship_x, 0.2, 0.8},
		{ship_x, 0.2, 0.05},
		{ship_x + 0.95, 0.12, -0.2},
		ship_color,
	)
	rl.DrawSphere({ship_x, 0.28, 0}, 0.35 + pulse * 0.1, rl.WHITE)
	rl.EndMode3D()
}

main :: proc() {
	if len(os.args) == 2 && os.args[1] == "--self-test" {
		self_test()
		return
	}
	if len(os.args) != 2 {
		fmt.eprintln("usage: ./psycho <music.wav|mp3|ogg|flac>\n       ./psycho --self-test")
		return
	}

	audio_path := os.args[1]
	file_bytes, file_err := os.read_entire_file(audio_path, context.allocator)
	if file_err != nil {
		fmt.eprintfln("psycho: cannot read %q: %v", audio_path, file_err)
		return
	}
	map_path := cache_path(file_bytes)
	delete(file_bytes)
	defer delete(map_path)
	path_c := strings.clone_to_cstring(audio_path, context.temp_allocator)

	nodes, cache_hit := load_map(map_path)
	if cache_hit {
		fmt.printfln("map: loaded %s (%d slices)", map_path, len(nodes))
	} else {
		fmt.println(
			"map: listening for movements, beats, climbs, drops and strange little roads...",
		)
		nodes = analyze_file(path_c)
		if len(nodes) == 0 {
			fmt.eprintln("psycho: unsupported or invalid audio file")
			return
		}
		movements: [4]int
		traffic, surprises: int
		previous_section: i32 = -1
		for node in nodes {
			if node.section != previous_section {
				movements[node.section] += 1
				previous_section = node.section
			}
			if node.kind != 0 do traffic += 1
			if node.feature != 0 do surprises += 1
		}
		fmt.printfln(
			"map: composed %d climbs, %d drops, %d slaloms, %d tunnels, %d traffic, %d gates",
			movements[CLIMB],
			movements[DROP],
			movements[SLALOM],
			movements[TUNNEL],
			traffic,
			surprises,
		)
		if save_map(map_path, nodes) {
			fmt.printfln("map: cached %s", map_path)
		} else {
			fmt.eprintln("map: warning: could not write cache")
		}
	}
	defer delete(nodes)

	rl.SetConfigFlags({.MSAA_4X_HINT, .VSYNC_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(1280, 720, "PSYCHO // sound ride")
	defer rl.CloseWindow()
	rl.SetTargetFPS(120)
	scene := rl.LoadRenderTexture(1280, 720)
	if !rl.IsRenderTextureValid(scene) {
		fmt.eprintln("psycho: could not create render target")
		return
	}
	defer rl.UnloadRenderTexture(scene)
	shader := rl.LoadShaderFromMemory(nil, PSYCHO_SHADER)
	defer rl.UnloadShader(shader)
	time_loc := rl.GetShaderLocation(shader, "time")
	energy_loc := rl.GetShaderLocation(shader, "energy")
	pulse_loc := rl.GetShaderLocation(shader, "pulse")
	amount_loc := rl.GetShaderLocation(shader, "amount")
	rl.InitAudioDevice()
	defer rl.CloseAudioDevice()
	if !rl.IsAudioDeviceReady() {
		fmt.eprintln("psycho: audio device unavailable")
		return
	}
	music := rl.LoadMusicStream(path_c)
	if !rl.IsMusicValid(music) {
		fmt.eprintln("psycho: could not stream audio")
		return
	}
	defer rl.UnloadMusicStream(music)
	rl.SetMusicVolume(music, 0.65)
	volume: f32 = 0.65
	fx_rate = f64(music.sampleRate)
	fx_channels = int(music.channels)
	if fx_channels >= 2 {
		rl.AttachAudioStreamProcessor(music.stream, audio_fx)
		defer rl.DetachAudioStreamProcessor(music.stream, audio_fx)
	}
	rl.PlayMusicStream(music)

	player_lane: f32
	last_index := 0
	score, streak, best_streak, color_chain, crashes: int
	last_tone: i32
	last_tone = -1
	shield := 3
	paused, finished: bool
	visual_fx := true
	visual_amount: f32 = 0.65
	pulse, shake, overdrive: f32
	for !rl.WindowShouldClose() {
		rl.UpdateMusicStream(music)
		dt := min(rl.GetFrameTime(), 0.05)
		if rl.IsKeyPressed(.SPACE) {
			paused = !paused
			if paused do rl.PauseMusicStream(music)
			else do rl.ResumeMusicStream(music)
		}
		if rl.IsKeyPressed(.B) && fx_channels >= 2 do fx_on = !fx_on
		if rl.IsKeyPressed(.P) do visual_fx = !visual_fx
		if rl.IsKeyPressed(.COMMA) do visual_amount = max(0, visual_amount - 0.1)
		if rl.IsKeyPressed(.PERIOD) do visual_amount = min(1, visual_amount + 0.1)
		if rl.IsKeyPressed(.F) do rl.ToggleFullscreen()
		if rl.IsKeyPressed(.LEFT_BRACKET) do fx_amount = max(0, fx_amount - 0.05)
		if rl.IsKeyPressed(.RIGHT_BRACKET) do fx_amount = min(0.5, fx_amount + 0.05)
		if rl.IsKeyPressed(.MINUS) {
			volume = max(0, volume - 0.05)
			rl.SetMusicVolume(music, volume)
		}
		if rl.IsKeyPressed(.EQUAL) {
			volume = min(0.8, volume + 0.05)
			rl.SetMusicVolume(music, volume)
		}
		move := steer_input(
			rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT),
			rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT),
		)
		player_lane = clamp(player_lane + move * dt * 2.2, -1, 1)

		time_played := rl.GetMusicTimePlayed(music)
		node_time := time_played / STEP
		current := clamp(int(node_time), 0, len(nodes) - 1)
		fraction := clamp(node_time - f32(current), 0, 1)
		if current > last_index {
			for i in last_index + 1 ..= current {
				node := nodes[i]
				aligned := abs(player_lane - f32(node.lane)) < 0.43
				if node.kind == PICKUP {
					if aligned {
						streak += 1
						if node.tone == last_tone do color_chain += 1
						else do color_chain = 1
						last_tone = node.tone
						multiplier := max(1, min(8, streak / 3 + color_chain))
						if overdrive > 0 do multiplier *= 2
						score += int(120 * node.beat + 25) * multiplier
						best_streak = max(best_streak, streak)
						pulse = 1
						fx_tingle = 1
					} else {
						streak = 0
						color_chain = 0
						last_tone = -1
					}
				} else if node.kind == HAZARD && aligned {
					shield -= 1
					score = max(0, score - 350)
					streak, color_chain, last_tone = 0, 0, -1
					shake, pulse = 1, 1
					if shield <= 0 {
						crashes += 1
						shield = 3
						score /= 2
					}
				} else if node.kind == SHIELD && aligned {
					shield = min(3, shield + 1)
					score += 300
					pulse = 1
				} else if node.kind == BOOST && aligned {
					overdrive = 6
					score += 500
					pulse, fx_tingle = 1, 1
				}
			}
			last_index = current
		}
		pulse = max(0, pulse - dt * 2.8)
		shake = max(0, shake - dt * 4.5)
		overdrive = max(0, overdrive - dt)
		fx_tingle = max(0, fx_tingle - dt * 2.0)
		fx_beat_hz = 4.0 + f64(nodes[current].bass) * 6.0
		finished = current >= len(nodes) - 2 && !rl.IsMusicStreamPlaying(music)
		if finished && rl.IsKeyPressed(.R) {
			rl.SeekMusicStream(music, 0)
			rl.PlayMusicStream(music)
			last_index, score, streak, color_chain, last_tone, crashes = 0, 0, 0, 0, -1, 0
			shield = 3
			overdrive = 0
			finished = false
		}

		w, h := rl.GetScreenWidth(), rl.GetScreenHeight()
		energy := nodes[current].bass * 0.6 + nodes[current].mid * 0.3 + nodes[current].high * 0.1
		bg := rl.Color{u8(4 + energy * 8), u8(3 + energy * 3), u8(14 + energy * 18), 255}
		rl.BeginTextureMode(scene)
		rl.ClearBackground(bg)
		rl.BeginBlendMode(.ADDITIVE)
		for ring in 0 ..< 5 {
			radius := f32(90 + ring * 95) + pulse * 30
			rl.DrawCircleLines(640, 360, radius, rl.Color{30, u8(40 + ring * 25), 120, 70})
		}
		rl.EndBlendMode()
		draw_ride(nodes, current, fraction, player_lane, pulse, shake)
		rl.EndTextureMode()

		shader_time := f32(rl.GetTime())
		rl.SetShaderValue(shader, time_loc, &shader_time, .FLOAT)
		rl.SetShaderValue(shader, energy_loc, &energy, .FLOAT)
		rl.SetShaderValue(shader, pulse_loc, &pulse, .FLOAT)
		visual_power := min(1, visual_amount + overdrive * 0.035)
		rl.SetShaderValue(shader, amount_loc, &visual_power, .FLOAT)
		source := rl.Rectangle{0, 0, f32(scene.texture.width), -f32(scene.texture.height)}
		destination := rl.Rectangle{0, 0, f32(w), f32(h)}
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		if visual_fx && rl.IsShaderValid(shader) do rl.BeginShaderMode(shader)
		rl.DrawTexturePro(scene.texture, source, destination, {}, 0, rl.WHITE)
		if visual_fx && rl.IsShaderValid(shader) do rl.EndShaderMode()

		rl.DrawRectangle(22, 20, 470, 92, rl.Color{2, 4, 16, 205})
		rl.DrawText("PSYCHO", 36, 30, 32, rl.Color{255, 80, 210, 255})
		rl.DrawText(
			rl.TextFormat("SCORE %08d   STREAK x%d   CHAIN x%d", score, streak, color_chain),
			36,
			72,
			20,
			rl.WHITE,
		)
		progress := f32(current) / f32(max(1, len(nodes) - 1))
		rl.DrawRectangle(36, 98, 430, 4, rl.Color{30, 30, 55, 255})
		rl.DrawRectangle(36, 98, i32(430 * progress), 4, rl.Color{50, 220, 255, 255})
		for hull in 0 ..< 3 {
			hull_color := rl.Color{45, 55, 80, 255}
			if hull < shield do hull_color = rl.Color{70, 255, 145, 255}
			rl.DrawRectangle(w - 150 + i32(hull * 34), 52, 26, 8, hull_color)
		}
		rl.DrawText(
			rl.TextFormat("CRASHES %d", crashes),
			w - 150,
			70,
			15,
			rl.Color{180, 190, 215, 255},
		)
		section_names := [4]cstring{"CLIMB", "DROP", "SLALOM", "TUNNEL"}
		rl.DrawText(
			rl.TextFormat(
				"%s  SPEED %.0f%%",
				section_names[nodes[current].section],
				38 + nodes[current].pace * 200,
			),
			w - 210,
			96,
			18,
			rl.Color{255, 215, 90, 255},
		)
		if overdrive > 0 {
			rl.DrawText("OVERDRIVE x2", w / 2 - 100, 28, 25, rl.Color{255, 220, 55, 255})
			rl.DrawRectangle(
				w / 2 - 100,
				58,
				i32(overdrive / 6 * 200),
				5,
				rl.Color{255, 100, 50, 255},
			)
		}
		fx_label: cstring = "EXPERIMENTAL FX: OFF [B]"
		if fx_channels < 2 do fx_label = "EXPERIMENTAL FX: NEEDS STEREO"
		if fx_on do fx_label = rl.TextFormat("EXPERIMENTAL FX: %.0f%% [B]", fx_amount * 100)
		rl.DrawText(fx_label, 24, h - 58, 17, rl.Color{150, 190, 225, 255})
		visual_label: cstring = "PSYCHO VISUAL: ON [P]"
		if !visual_fx do visual_label = "PSYCHO VISUAL: OFF [P]"
		rl.DrawText(visual_label, 24, h - 82, 17, rl.Color{190, 130, 245, 255})
		rl.DrawText(
			"A/D steer   SPACE pause   P visual   ,/. visual power   B audio FX   [/] audio power   -/+ volume",
			24,
			h - 32,
			14,
			rl.Color{130, 140, 170, 255},
		)
		rl.DrawText(
			rl.TextFormat("VOL %.0f%%", volume * 100),
			w - 105,
			24,
			17,
			rl.Color{150, 190, 225, 255},
		)
		if paused {
			rl.DrawRectangle(0, 0, w, h, rl.Color{0, 0, 0, 130})
			rl.DrawText("PAUSED", w / 2 - 88, h / 2 - 25, 42, rl.WHITE)
		}
		if finished {
			rl.DrawRectangle(0, 0, w, h, rl.Color{0, 0, 0, 185})
			rl.DrawText("RIDE COMPLETE", w / 2 - 190, h / 2 - 72, 44, rl.Color{255, 90, 220, 255})
			rl.DrawText(
				rl.TextFormat("SCORE %d   BEST STREAK %d", score, best_streak),
				w / 2 - 180,
				h / 2,
				22,
				rl.WHITE,
			)
			rl.DrawText(
				"press R to ride again",
				w / 2 - 130,
				h / 2 + 42,
				20,
				rl.Color{130, 220, 255, 255},
			)
		}
		rl.EndDrawing()
	}
}
