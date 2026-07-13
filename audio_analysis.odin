package main

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:os"
import rl "vendor:raylib"

MAP_MAGIC :: u64(0x50535943484f3031) // PSYCHO01
MAP_VERSION :: u32(1)
STEP :: f32(0.10)

Cache_Header :: struct {
	magic:          u64,
	version, count: u32,
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
		if node_i > 3 &&
		   node_i - last_beat > 2 &&
		   nodes[node_i].onset >= 0.24 &&
		   nodes[node_i].onset >= previous_flux &&
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
		nodes[node_i].tempo = clamp(
			bpm_normalized * confidence + nodes[node_i].activity * 0.16,
			0,
			1,
		)
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

	compose_track(nodes, song_seed)
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
