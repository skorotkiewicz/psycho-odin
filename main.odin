package main

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

MAP_MAGIC :: u64(0x50535943484f3031) // PSYCHO01
MAP_VERSION :: u32(8)
STEP :: f32(0.10)
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
	mean_energy, max_energy: f32
	song_seed: u32 = 2166136261

	// First pass: three broad perceptual bands. The later offline passes combine these with
	// song-relative dynamics and rhythm, which is more useful to the road than raw loudness.
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
		raw_energy := bass * 0.9 + mid * 0.65 + high * 0.35
		nodes[node_i].energy = raw_energy
		mean_energy += raw_energy
		max_energy = max(max_energy, raw_energy)
		song_seed = (song_seed ~ u32((bass * 997 + mid * 619 + high * 389) * 1_000_000)) * 16777619
	}
	mean_energy = max(mean_energy / f32(count), 0.0001)

	// A small histogram gives robust quiet/loud anchors without sorting a copy of the song.
	// This deliberately amplifies useful dynamics in heavily compressed masters.
	energy_histogram: [256]int
	if max_energy > 0 {
		for node in nodes {
			bucket := clamp(int(node.energy / max_energy * 255), 0, 255)
			energy_histogram[bucket] += 1
		}
	}
	floor_bucket, ceiling_bucket: int
	seen := 0
	floor_found := false
	for bucket in 0 ..< len(energy_histogram) {
		seen += energy_histogram[bucket]
		if !floor_found && seen >= max(1, count * 12 / 100) {
			floor_bucket = bucket
			floor_found = true
		}
		if seen >= max(1, count * 92 / 100) {
			ceiling_bucket = bucket
			break
		}
	}
	energy_floor := max_energy * f32(floor_bucket) / 255
	energy_ceiling := max_energy * f32(ceiling_bucket) / 255
	if energy_ceiling - energy_floor < mean_energy * 0.12 {
		energy_floor = max(0, mean_energy * 0.82)
		energy_ceiling = mean_energy * 1.18
	}
	energy_range := max(energy_ceiling - energy_floor, 0.0001)

	// Second pass normalizes every song against its own dynamic range, so a quiet master and
	// a loud master both produce readable climbs and drops.
	for node_i in 0 ..< count {
		node := &nodes[node_i]
		intensity := clamp((node.energy - energy_floor) / energy_range, 0, 1)
		intensity = intensity * intensity * (3 - 2 * intensity)
		band_scale := 1 / max(energy_ceiling * 1.35, mean_energy * 1.8)
		node.bass = clamp(node.bass * band_scale, 0, 1)
		node.mid = clamp(node.mid * band_scale, 0, 1)
		node.high = clamp(node.high * band_scale, 0, 1)
		node.energy = intensity
	}

	// Adaptive spectral flux finds changes rather than merely loud samples. A local threshold
	// makes subtle hi-hats in quiet songs and hard snares in loud songs both useful.
	raw_onset := make([]f32, count)
	defer delete(raw_onset)
	prior_bass, prior_mid, prior_high, prior_energy: f32
	for node_i in 0 ..< count {
		node := &nodes[node_i]
		flux :=
			max(0, node.bass - prior_bass) * 0.75 +
			max(0, node.mid - prior_mid) * 0.4 +
			max(0, node.high - prior_high) * 0.24 +
			max(0, node.energy - prior_energy) * 0.18
		raw_onset[node_i] = flux
		prior_bass, prior_mid, prior_high, prior_energy =
			node.bass, node.mid, node.high, node.energy
	}

	for node_i in 0 ..< count {
		local_flux: f32
		local_count: int
		for look := max(0, node_i - 12); look <= min(count - 1, node_i + 12); look += 1 {
			if abs(look - node_i) > 1 {
				local_flux += raw_onset[look]
				local_count += 1
			}
		}
		local_flux /= f32(max(1, local_count))
		surprise := raw_onset[node_i] / max(0.012, local_flux * 1.35)
		nodes[node_i].onset = clamp((surprise - 0.72) / 1.7, 0, 1)
	}

	last_beat := -10
	for node_i in 0 ..< count {
		previous_flux := nodes[max(0, node_i - 1)].onset
		next_flux := nodes[min(count - 1, node_i + 1)].onset
		if node_i > 3 && node_i - last_beat > 2 &&
		   nodes[node_i].onset >= 0.24 && nodes[node_i].onset >= previous_flux &&
		   nodes[node_i].onset >= next_flux {
			nodes[node_i].beat = nodes[node_i].onset
			nodes[node_i].kind = PICKUP
			last_beat = node_i
		}
	}

	// Local autocorrelation distinguishes a dense fast beat from an equally loud sustained
	// passage. At 100 ms resolution, lags 3..10 cover roughly 200..60 BPM.
	for node_i in 0 ..< count {
		window_start := max(0, node_i - 48)
		window_end := min(count - 1, node_i + 48)
		best_lag := 10
		best_score: f32
		for lag in 3 ..= 10 {
			correlation, left_power, right_power: f32
			for look := window_start + lag; look <= window_end; look += 1 {
				left := nodes[look].onset
				right := nodes[look - lag].onset
				correlation += left * right
				left_power += left * left
				right_power += right * right
			}
			score := correlation / f32(math.sqrt(f64(max(0.0001, left_power * right_power))))
			// Prefer the faster fundamental slightly when a half-time harmonic scores equally.
			score *= 1 + f32(10 - lag) * 0.012
			if score > best_score {
				best_score = score
				best_lag = lag
			}
		}
		activity: f32
		for look := max(0, node_i - 10); look <= min(count - 1, node_i + 10); look += 1 {
			activity += nodes[look].onset
		}
		activity /= f32(min(count - 1, node_i + 10) - max(0, node_i - 10) + 1)
		nodes[node_i].activity = clamp(activity * 2.8, 0, 1)
		bpm_normalized := clamp((600 / f32(best_lag) - 60) / 140, 0, 1)
		confidence := clamp((best_score - 0.16) / 0.55, 0, 1)
		nodes[node_i].tempo =
			clamp(bpm_normalized * confidence + nodes[node_i].activity * 0.16, 0, 1)
	}

	// Offline look-around lets the road crest just before a musical drop instead of lagging it.
	raw_pace := make([]f32, count)
	defer delete(raw_pace)
	for node_i in 0 ..< count {
		texture := clamp(nodes[node_i].mid + nodes[node_i].high, 0, 1)
		raw_pace[node_i] = clamp(
			nodes[node_i].energy * 0.58 +
			nodes[node_i].activity * 0.18 +
			nodes[node_i].tempo * 0.18 +
			texture * 0.06,
			0,
			1,
		)
	}
	for node_i in 0 ..< count {
		pace_sum, weight_sum, coming_peak: f32
		for look := max(0, node_i - 7); look <= min(count - 1, node_i + 11); look += 1 {
			delta := abs(look - node_i)
			weight := 1 / f32(1 + delta)
			pace_sum += raw_pace[look] * weight
			weight_sum += weight
			if look >= node_i do coming_peak = max(coming_peak, raw_pace[look])
		}
		pace := pace_sum / weight_sum * 0.82 + coming_peak * 0.18
		nodes[node_i].pace = clamp(pace, 0, 1)
	}

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

mouse_lane_target :: proc(mouse_x, screen_width: i32) -> f32 {
	if screen_width <= 1 do return 0
	// The outer 8% on either side is already full lock, keeping steering reachable in a window.
	center := f32(screen_width) * 0.5
	half_control_width := f32(screen_width) * 0.42
	return clamp((center - f32(mouse_x)) / half_control_width, -1, 1)
}

smooth_mouse_lane :: proc(current, target, dt: f32) -> f32 {
	response := 1 - f32(math.exp(f64(-18 * max(0, dt))))
	return clamp(current + (target - current) * response, -1, 1)
}

lane_position :: proc(road_width, normalized_lane: f32) -> f32 {
	return normalized_lane * road_width * 2 / 3
}

pace_color :: proc(pace, value: f32, alpha: u8 = 255) -> rl.Color {
	// Cool cyan climbs travel through violet into hot gold/red descents.
	p := clamp(pace, 0, 1)
	heat := p * p * (3 - 2 * p)
	hue := 195 + heat * 187
	color := rl.ColorFromHSV(hue, 0.62 + p * 0.34, clamp(value, 0, 1))
	color.a = alpha
	return color
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
		bounds.min_x, bounds.max_x = min(bounds.min_x, node.curve_x), max(bounds.max_x, node.curve_x)
		bounds.min_z, bounds.max_z = min(bounds.min_z, node.curve_z), max(bounds.max_z, node.curve_z)
	}
	return bounds
}

draw_course_map :: proc(
	nodes: []Track_Node,
	current: int,
	x, y, width, height: i32,
	bounds: Course_Map_Bounds,
) {
	if len(nodes) < 2 || width < 80 || height < 50 do return
	rl.DrawRectangle(x, y, width, height, rl.Color{2, 5, 17, 218})
	rl.DrawRectangleLines(x, y, width, height, rl.Color{80, 135, 190, 130})
	rl.DrawText("RIDE MAP  //  HEIGHT + TURNS", x + 11, y + 8, 13, rl.Color{160, 205, 235, 230})

	left, top := f32(x + 11), f32(y + 28)
	total_width, plot_height := f32(width - 22), f32(height - 39)
	profile_width := total_width * 0.70
	plan_gap: f32 = 12
	plan_left := left + profile_width + plan_gap
	plan_width := total_width - profile_width - plan_gap
	rl.DrawLine(
		i32(plan_left - plan_gap * 0.5),
		i32(top),
		i32(plan_left - plan_gap * 0.5),
		i32(top + plot_height),
		rl.Color{70, 95, 135, 105},
	)
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
	rl.DrawCircleV(marker, 5.5, rl.Color{2, 5, 17, 255})
	rl.DrawCircleLines(i32(marker.x), i32(marker.y), 6, rl.WHITE)
	rl.DrawCircleV(marker, 2.2, pace_color(nodes[current].pace, 1))
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
	rl.DrawCircleV(plan_marker, 4.5, rl.Color{2, 5, 17, 255})
	rl.DrawCircleLines(i32(plan_marker.x), i32(plan_marker.y), 5, rl.WHITE)
	rl.DrawCircleV(plan_marker, 1.8, pace_color(nodes[current].pace, 1))
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
	min_heading, max_heading, min_pitch, max_pitch: f32
	for node in nodes {
		min_x, max_x = min(min_x, node.curve_x), max(max_x, node.curve_x)
		min_y, max_y = min(min_y, node.curve_y), max(max_y, node.curve_y)
	}
	for i in 1 ..< len(nodes) {
		dx := nodes[i].curve_x - nodes[i - 1].curve_x
		dy := nodes[i].curve_y - nodes[i - 1].curve_y
		dz := nodes[i].curve_z - nodes[i - 1].curve_z
		heading := f32(math.atan2(f64(dx), f64(max(0.001, dz))))
		planar_step := f32(math.sqrt(f64(dx * dx + dz * dz)))
		pitch := f32(math.atan2(f64(dy), f64(max(0.001, planar_step))))
		spatial_step := f32(math.sqrt(f64(dx * dx + dy * dy + dz * dz)))
		arc_step := nodes[i].distance - nodes[i - 1].distance
		assert(dz > 0, "cached centerline must always move forward")
		assert(abs(spatial_step - arc_step) < 0.01, "cached distance must match 3D centerline arc length")
		assert(abs(heading - nodes[i].heading) < 0.001, "cached heading must match centerline tangent")
		assert(abs(pitch - nodes[i].pitch) < 0.001, "cached pitch must match centerline tangent")
		min_heading = min(min_heading, heading)
		max_heading = max(max_heading, heading)
		min_pitch = min(min_pitch, pitch)
		max_pitch = max(max_pitch, pitch)
	}
	fmt.printfln(
		"self-test: centerline yaw %.1f° left / %.1f° right; pitch %.1f° up / %.1f° down",
		f64(max_heading) * 180 / math.PI,
		f64(min_heading) * 180 / math.PI,
		f64(max_pitch) * 180 / math.PI,
		f64(min_pitch) * 180 / math.PI,
	)
	assert(pickups > 0 && hazards > 0)
	assert(card(sections) == 4)
	assert(max_x - min_x > 16 && max_y - min_y > 18 && features > 4)
	assert(max_heading > 0.24 && min_heading < -0.24, "road must make visible turns both ways")
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
	assert(future_center.z > 1, "future cached centerline must remain ahead in the local tangent frame")
	assert(abs(future_center.x) > 0.1, "future tangent transform must expose the upcoming bend")
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
	preview_jump := f32(math.sqrt(f64(preview_dx * preview_dx + preview_dy * preview_dy + preview_dz * preview_dz)))
	fmt.printfln("self-test: camera preview cache-boundary jump %.3f", preview_jump)
	assert(preview_jump < 0.10, "camera preview must move continuously across cached audio slices")
	assert(abs(lane_position(4.8, 1) - 3.2) < 0.001)
	assert(steer_input(true, false) > 0, "A/left must move toward screen-left for a +Z camera")
	assert(mouse_lane_target(0, 1000) > 0.99)
	assert(abs(mouse_lane_target(500, 1000)) < 0.001)
	assert(mouse_lane_target(1000, 1000) < -0.99)
	mouse_step := smooth_mouse_lane(0, 1, 1.0 / 60.0)
	assert(mouse_step > 0 && mouse_step < 1)

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
	quiet_run := f32(math.sqrt(f64(max(0.001, quiet_speed * quiet_speed - quiet_slope * quiet_slope))))
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
	assert(quiet_angle > 0.10 && loud_angle < -0.10, "climbs and drops must remain visible at speed")

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

road_bank :: proc(nodes: []Track_Node, i: int) -> f32 {
	node_i := clamp(i, 0, len(nodes) - 1)
	previous := nodes[max(0, node_i - 1)]
	next := nodes[min(len(nodes) - 1, node_i + 1)]
	return clamp((next.heading - previous.heading) * 3.6, -0.68, 0.68)
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

track_sample_indices :: proc(nodes: []Track_Node, node_position: f32) -> (i, next_i: int, fraction: f32) {
	position := clamp(node_position, 0, f32(len(nodes) - 1))
	i = int(position)
	next_i = min(i + 1, len(nodes) - 1)
	fraction = position - f32(i)
	return
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

draw_ride :: proc(
	nodes: []Track_Node,
	current: int,
	fraction, player_lane, steer_lean, pulse, shake: f32,
) {
	next_i := min(current + 1, len(nodes) - 1)
	base_x := nodes[current].curve_x + (nodes[next_i].curve_x - nodes[current].curve_x) * fraction
	base_y := nodes[current].curve_y + (nodes[next_i].curve_y - nodes[current].curve_y) * fraction
	base_z := nodes[current].curve_z + (nodes[next_i].curve_z - nodes[current].curve_z) * fraction
	base_heading := nodes[current].heading + (nodes[next_i].heading - nodes[current].heading) * fraction
	base_pitch := nodes[current].pitch + (nodes[next_i].pitch - nodes[current].pitch) * fraction
	base_width := nodes[current].width + (nodes[next_i].width - nodes[current].width) * fraction
	base_bank := road_bank(nodes, current) + (road_bank(nodes, next_i) - road_bank(nodes, current)) * fraction
	shake_x := f32(math.sin(rl.GetTime() * 61)) * shake * 0.24
	shake_y := f32(math.sin(rl.GetTime() * 47)) * shake * 0.18
	playhead := f32(current) + fraction
	pace := pace_sample(nodes, playhead)
	pace_curve := pace * pace * (3 - 2 * pace)
	near_position := playhead + 8
	far_position := playhead + 18 + pace * 8
	preview_position := playhead + 10
	near_look := road_center_sample(nodes, near_position, base_x, base_y, base_z, base_heading)
	far_look := road_center_sample(nodes, far_position, base_x, base_y, base_z, base_heading)
	future_heading := heading_sample(nodes, preview_position)
	future_pitch := pitch_sample(nodes, preview_position)
	turn_preview := clamp(future_heading - base_heading, -0.7, 0.7)
	pitch_preview := clamp(future_pitch - base_pitch, -0.45, 0.45)
	camera_bank := clamp(turn_preview * 0.48 + steer_lean * 0.035, -0.29, 0.29)
	player_x := lane_position(base_width, player_lane)
	// A chase camera should lag the route. Fully aiming at the far centerline mathematically
	// cancels the yaw/pitch that the player needs to see in order to feel the rollercoaster.
	target_x := clamp(near_look.x * 0.10 + far_look.x * 0.18, -18, 18) + player_x * 0.06
	target_y := clamp(near_look.y * 0.08 + far_look.y * 0.14, -12, 12)
	turn_fov := min(11, abs(turn_preview) * 24)
	pitch_fov := min(8, abs(pitch_preview) * 24)
	camera_ground_y := -(player_x * 0.72) * base_bank
	camera := rl.Camera3D {
		position   = {
			player_x * 0.72 + shake_x,
			camera_ground_y + 2.55 + abs(turn_preview) * 0.8 + abs(pitch_preview) * 1.2 + shake_y,
			-6.35,
		},
		target     = {target_x, target_y + 0.05, max(24, far_look.z)},
		up         = {-camera_bank, 1, 0},
		fovy       = 66 + pace_curve * 18 + turn_fov + pitch_fov,
		projection = .PERSPECTIVE,
	}
	rl.BeginMode3D(camera)

	for i := current; i < min(len(nodes) - 1, current + 100); i += 1 {
		node := nodes[i]
		left := road_point(nodes, i, -node.width, base_x, base_y, base_z, base_heading)
		right := road_point(nodes, i, node.width, base_x, base_y, base_z, base_heading)
		next_left := road_point(nodes, i + 1, -nodes[i + 1].width, base_x, base_y, base_z, base_heading)
		next_right := road_point(nodes, i + 1, nodes[i + 1].width, base_x, base_y, base_z, base_heading)
		center := road_point(nodes, i, 0, base_x, base_y, base_z, base_heading)
		surface_value := clamp(
			0.19 + node.pace * 0.28 + node.energy * 0.28 + node.mid * 0.20,
			0,
			0.82,
		)
		// Shade each lane independently: this makes steering and traffic readable at speed.
		for lane_i in 0 ..< 3 {
			near_left_offset := -node.width + f32(lane_i) * node.width * 2 / 3
			near_right_offset := -node.width + f32(lane_i + 1) * node.width * 2 / 3
			far_left_offset :=
				-nodes[i + 1].width + f32(lane_i) * nodes[i + 1].width * 2 / 3
			far_right_offset :=
				-nodes[i + 1].width + f32(lane_i + 1) * nodes[i + 1].width * 2 / 3
			lane_left := road_point(nodes, i, near_left_offset, base_x, base_y, base_z, base_heading)
			lane_right := road_point(nodes, i, near_right_offset, base_x, base_y, base_z, base_heading)
			lane_next_left :=
				road_point(nodes, i + 1, far_left_offset, base_x, base_y, base_z, base_heading)
			lane_next_right :=
				road_point(nodes, i + 1, far_right_offset, base_x, base_y, base_z, base_heading)
			lane_lift: f32
			if lane_i == 1 do lane_lift = 0.045
			lane_color := pace_color(node.pace, surface_value + lane_lift, 225)
			rl.DrawTriangle3D(lane_left, lane_next_left, lane_right, lane_color)
			rl.DrawTriangle3D(lane_right, lane_next_left, lane_next_right, lane_color)
		}

		grid_color := pace_color(node.pace, 0.58 + node.pace * 0.32, 105)
		if i % 2 == 0 {
			rl.DrawLine3D(
				lift_road_overlay(left, 0.035),
				lift_road_overlay(right, 0.035),
				grid_color,
			)
		}
		if node.beat > 0.22 {
			beat_color := pace_color(node.pace, 1, u8(150 + node.beat * 100))
			rl.DrawLine3D(
				lift_road_overlay(left, 0.075),
				lift_road_overlay(right, 0.075),
				beat_color,
			)
		}
		rail_color := pace_color(node.pace, 0.78 + node.pace * 0.2, 245)
		rl.DrawCylinderEx(left, next_left, 0.045 + node.pace * 0.025, 0.045, 5, rail_color)
		rl.DrawCylinderEx(right, next_right, 0.045 + node.pace * 0.025, 0.045, 5, rail_color)
		if i % 2 == 0 {
			for lane_mark in -1 ..= 1 {
				if lane_mark == 0 do continue
				mark := f32(lane_mark) * node.width / 3
				next_mark := f32(lane_mark) * nodes[i + 1].width / 3
				p0 := road_point(nodes, i, mark, base_x, base_y, base_z, base_heading)
				p1 := road_point(nodes, i + 1, next_mark, base_x, base_y, base_z, base_heading)
				rl.DrawLine3D(
					lift_road_overlay(p0, 0.055),
					lift_road_overlay(p1, 0.055),
					rl.Color{205, 225, 255, 145},
				)
			}
		}

		if node.kind != 0 && i > current + 1 {
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

		if node.feature != 0 {
			tl, tr := left, right
			height: f32 = 5.6
			feature_color := pace_color(node.pace, 0.88, 175)
			if node.feature == ARCH {
				height = 4.8
				feature_color = pace_color(node.pace, 0.72, 145)
			} else if node.feature == PORTAL || node.feature == RAMP {
				height = 7.2
				feature_color = pace_color(max(0.72, node.pace), 1, 220)
			}
			tl.y += height
			tr.y += height
			rl.DrawLine3D(left, tl, feature_color)
			rl.DrawLine3D(right, tr, feature_color)
			rl.DrawLine3D(tl, tr, feature_color)
			if node.feature == PORTAL || node.feature == RAMP {
				rl.DrawLine3D(left, tr, pace_color(node.pace, 1, 145))
				rl.DrawLine3D(right, tl, pace_color(1 - node.pace, 0.9, 120))
			}
		}
		if node.section == DROP && i % 7 == 0 {
			tower_color := pace_color(node.pace, 0.38 + node.energy * 0.36, 180)
			rl.DrawCube(
				{left.x - 2.5, left.y - 3.5, center.z},
				1.2,
				7,
				1.2,
				tower_color,
			)
			rl.DrawCube(
				{right.x + 2.5, right.y - 3.5, center.z},
				1.2,
				7,
				1.2,
				tower_color,
			)
		}
		if i % 6 == 0 {
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
		if i % 5 == 0 {
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
			{
				ship_x + steer_lean * f32(trail) * 0.018,
				ship_y,
				-f32(trail) * (0.52 + pace * 0.28),
			},
			ship_y,
			base_pitch,
		)
		rl.DrawSphere(
			trail_point,
			0.29 / f32(trail) + 0.05,
			trail_color,
		)
	}
	wing_tilt := steer_lean * 0.24
	body_back := pitch_around({ship_x, ship_y, -0.45}, ship_y, base_pitch)
	body_front := pitch_around({ship_x, ship_y, 2.0}, ship_y, base_pitch)
	rl.DrawCylinderEx(
		body_back,
		body_front,
		0.56,
		0.08,
		8,
		pace_color(pace, 0.46),
	)
	rl.DrawCylinderWiresEx(
		body_back,
		body_front,
		0.56,
		0.08,
		8,
		rl.Color{235, 245, 255, 230},
	)
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
	rl.DrawTriangle3D(
		ship_nose,
		ship_left,
		ship_center,
		ship_color,
	)
	rl.DrawTriangle3D(
		ship_nose,
		ship_center,
		ship_right,
		ship_color,
	)
	for side in -1 ..= 1 {
		if side == 0 do continue
		pod_x := ship_x + f32(side) * 0.55
		pod_y := ship_y - f32(side) * (base_bank * 0.55 + wing_tilt * 0.35)
		pod_back := pitch_around({pod_x, pod_y, -0.46}, ship_y, base_pitch)
		pod_front := pitch_around({pod_x, pod_y, 0.72}, ship_y, base_pitch)
		rl.DrawCylinderEx(
			pod_back,
			pod_front,
			0.24,
			0.13,
			7,
			pace_color(pace, 0.72),
		)
		rl.DrawSphere(pod_back, 0.22 + pace * 0.07, rl.WHITE)
	}
	cockpit := pitch_around({ship_x, ship_y + 0.24, 0.30}, ship_y, base_pitch)
	rl.DrawSphere(cockpit, 0.34 + pulse * 0.10, ship_color)
	rl.DrawSphereWires(cockpit, 0.37 + pulse * 0.10, 7, 7, rl.WHITE)
	rl.EndMode3D()
}

main :: proc() {
	if len(os.args) == 2 && os.args[1] == "--self-test" {
		self_test()
		return
	}
	analyze_only := len(os.args) == 3 && os.args[1] == "--analyze"
	if len(os.args) != 2 && !analyze_only {
		fmt.eprintln(
			"usage: ./psycho <music.wav|mp3|ogg|flac>\n" +
			"       ./psycho --analyze <music.wav|mp3|ogg|flac>\n" +
			"       ./psycho --self-test",
		)
		return
	}

	audio_path := os.args[1]
	if analyze_only do audio_path = os.args[2]
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
	if analyze_only {
		fmt.println("map: analysis complete")
		return
	}
	map_bounds := calculate_course_map_bounds(nodes)

	rl.SetConfigFlags({.MSAA_4X_HINT, .VSYNC_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(1280, 720, "PSYCHO // sound ride")
	defer rl.CloseWindow()
	rl.SetTargetFPS(120)
	scene := rl.LoadRenderTexture(rl.GetScreenWidth(), rl.GetScreenHeight())
	if !rl.IsRenderTextureValid(scene) {
		fmt.eprintln("psycho: could not create render target")
		return
	}
	defer {
		rl.UnloadRenderTexture(scene)
	}
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

	player_lane, steer_lean: f32
	mouse_active := false
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
		left_down := rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT)
		right_down := rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT)
		move := steer_input(left_down, right_down)
		lane_before_input := player_lane
		mouse_delta := rl.GetMouseDelta()
		if abs(mouse_delta.x) + abs(mouse_delta.y) > 0.15 || rl.IsMouseButtonPressed(.LEFT) {
			mouse_active = true
		}
		if left_down || right_down {
			mouse_active = false
			player_lane = clamp(player_lane + move * dt * 2.2, -1, 1)
		} else if mouse_active {
			target_lane := mouse_lane_target(rl.GetMouseX(), rl.GetScreenWidth())
			player_lane = smooth_mouse_lane(player_lane, target_lane, dt)
		}
		lane_speed := (player_lane - lane_before_input) / max(0.001, dt)
		target_lean := clamp(lane_speed * 0.28, -1, 1)
		steer_lean += (target_lean - steer_lean) * min(1, dt * 9)

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
		if rl.IsWindowResized() && w > 0 && h > 0 {
			resized_scene := rl.LoadRenderTexture(w, h)
			if rl.IsRenderTextureValid(resized_scene) {
				rl.UnloadRenderTexture(scene)
				scene = resized_scene
			}
		}
		energy := nodes[current].bass * 0.6 + nodes[current].mid * 0.3 + nodes[current].high * 0.1
		pace_now := nodes[current].pace
		pace_curve := pace_now * pace_now * (3 - 2 * pace_now)
		bg_top := pace_color(pace_now, 0.09 + pace_curve * 0.12)
		bg_bottom := pace_color(max(0, pace_now - 0.22), 0.018 + pace_curve * 0.032)
		rl.BeginTextureMode(scene)
		rl.ClearBackground(rl.BLACK)
		rl.DrawRectangleGradientV(0, 0, scene.texture.width, scene.texture.height, bg_top, bg_bottom)
		rl.BeginBlendMode(.ADDITIVE)
		scene_center_x := scene.texture.width / 2
		scene_center_y := scene.texture.height / 2
		scene_radius := f32(min(scene.texture.width, scene.texture.height))
		for ring in 0 ..< 5 {
			radius :=
				scene_radius * (0.12 + f32(ring) * 0.13) +
				pulse * 30 +
				pace_curve * f32(ring * 9)
			ring_color := pace_color(pace_now, 0.42 + f32(ring) * 0.08, 45 + u8(ring * 8))
			rl.DrawCircleLines(scene_center_x, scene_center_y, radius, ring_color)
		}
		rl.EndBlendMode()
		draw_ride(nodes, current, fraction, player_lane, steer_lean, pulse, shake)
		rl.EndTextureMode()

		shader_time := f32(rl.GetTime())
		rl.SetShaderValue(shader, time_loc, &shader_time, .FLOAT)
		visual_energy := clamp(energy * 0.35 + pace_now * 0.75, 0, 1)
		rl.SetShaderValue(shader, energy_loc, &visual_energy, .FLOAT)
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
		map_width := i32(clamp(f32(w) * 0.35, 280, 440))
		map_height := i32(clamp(f32(h) * 0.20, 140, 180))
		draw_course_map(nodes, current, 24, 124, map_width, map_height, map_bounds)
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
				52 + pace_curve * 275,
			),
			w - 210,
			96,
			18,
			pace_color(pace_now, 1),
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
			"A/D or MOUSE steer   SPACE pause   P visual   ,/. visual power   B audio FX   [/] audio power   -/+ volume",
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
		control_label: cstring = "KEYBOARD"
		if mouse_active do control_label = "MOUSE"
		rl.DrawText(
			rl.TextFormat("STEER %s", control_label),
			w - 120,
			h - 58,
			14,
			rl.Color{115, 190, 220, 210},
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
