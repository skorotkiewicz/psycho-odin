package main

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

MAP_MAGIC :: u64(0x50535943484f3031) // PSYCHO01
MAP_VERSION :: u32(1)
STEP :: f32(0.10)
ROAD_STEP :: f32(5.5)
LANE_WIDTH :: f32(2.6)

Track_Node :: struct {
	bass, mid, high:  f32,
	curve_x, curve_y: f32,
	beat:             f32,
	lane:             i32,
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
		noise := (f32(fx_noise & 0xffff) / 32767.5 - 1.0) * (0.0015 + fx_tingle * 0.004)
		pan := f32(math.sin(fx_pan_phase))
		tone := fx_amount * 0.025
		left := samples[frame * fx_channels] + f32(math.sin(fx_phase_l)) * tone + noise * (1 - pan)
		right :=
			samples[frame * fx_channels + 1] + f32(math.sin(fx_phase_r)) * tone + noise * (1 + pan)
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
	low, smooth_bass: f32
	last_beat := -10
	for node_i in 0 ..< count {
		start := node_i * frames_per_node
		finish := min(frame_count, start + frames_per_node)
		bass_sum, mid_sum, high_sum: f64
		previous: f32
		for frame in start ..< finish {
			sample: f32
			for channel in 0 ..< channels do sample += samples[frame * channels + channel]
			sample /= f32(channels)
			low += 0.035 * (sample - low)
			mid := sample - low
			high := sample - previous
			previous = sample
			bass_sum += f64(low * low)
			mid_sum += f64(mid * mid)
			high_sum += f64(high * high)
		}
		n := f64(max(1, finish - start))
		bass := f32(math.sqrt(bass_sum / n))
		mid := f32(math.sqrt(mid_sum / n))
		high := f32(math.sqrt(high_sum / n))
		smooth_bass = smooth_bass * 0.92 + bass * 0.08
		beat: f32
		if node_i - last_beat > 2 && node_i > 8 && bass > smooth_bass * 1.45 && bass > 0.015 {
			beat = clamp((bass / (smooth_bass + 0.0001) - 1.2) / 1.8, 0.25, 1)
			last_beat = node_i
		}
		t := f32(node_i) * STEP
		nodes[node_i] = Track_Node {
			bass    = clamp(bass * 4.5, 0, 1),
			mid     = clamp(mid * 3.5, 0, 1),
			high    = clamp(high * 2.8, 0, 1),
			curve_x = f32(math.sin(f64(t * 0.31 + bass * 3.0))) * 5.0,
			curve_y = f32(math.sin(f64(t * 0.19 + mid * 2.0))) * 1.2,
			beat    = beat,
			lane    = i32((u32(node_i) * 1664525 + 1013904223) % 3) - 1,
		}
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

self_test :: proc() {
	rate := 1000
	samples := make([]f32, rate * 2)
	defer delete(samples)
	for i in 0 ..< len(samples) {
		t := f64(i) / f64(rate)
		samples[i] = f32(math.sin(2 * math.PI * 80 * t)) * 0.1
		if i > 900 && i < 980 do samples[i] *= 4
	}
	nodes := analyze_samples(raw_data(samples), len(samples), rate, 1)
	defer delete(nodes)
	assert(len(nodes) == 20)
	assert(nodes[10].bass >= 0 && nodes[10].bass <= 1)

	path := ".psycho_cache/self-test.map"
	assert(save_map(path, nodes))
	loaded, ok := load_map(path)
	defer delete(loaded)
	assert(ok && len(loaded) == len(nodes) && loaded[0].lane == nodes[0].lane)
	fmt.println("self-test: ok")
}

draw_ride :: proc(nodes: []Track_Node, current: int, player_lane, pulse: f32) {
	base := nodes[current]
	camera := rl.Camera3D {
		position   = {player_lane * LANE_WIDTH * 0.35, 3.2, -8.5},
		target     = {
			(nodes[min(current + 8, len(nodes) - 1)].curve_x - base.curve_x) * 0.3,
			0.3,
			30,
		},
		up         = {0, 1, 0},
		fovy       = 72,
		projection = .PERSPECTIVE,
	}
	rl.BeginMode3D(camera)

	for i := current; i < min(len(nodes), current + 92); i += 1 {
		node := nodes[i]
		z := f32(i - current) * ROAD_STEP
		x := node.curve_x - base.curve_x
		y := node.curve_y - base.curve_y
		hue := f32((i * 3) % 360)
		color := rl.ColorFromHSV(hue + 190, 0.75, 0.35 + node.mid * 0.55)
		if i % 2 == 0 {
			rl.DrawLine3D({x - 4.2, y, z}, {x + 4.2, y, z}, color)
		}
		if i + 1 < len(nodes) {
			next := nodes[i + 1]
			nx, ny, nz := next.curve_x - base.curve_x, next.curve_y - base.curve_y, z + ROAD_STEP
			rl.DrawLine3D({x - 4.2, y, z}, {nx - 4.2, ny, nz}, color)
			rl.DrawLine3D({x + 4.2, y, z}, {nx + 4.2, ny, nz}, color)
			rl.DrawLine3D({x, y - 0.05, z}, {nx, ny - 0.05, nz}, rl.Color{80, 80, 120, 180})
		}
		if node.beat > 0 && i > current + 1 {
			orb_x := x + f32(node.lane) * LANE_WIDTH
			orb_color := rl.ColorFromHSV(hue + 20, 0.5, 1)
			rl.DrawSphere({orb_x, y + 0.8, z}, 0.28 + node.beat * 0.28, orb_color)
			rl.DrawSphereWires({orb_x, y + 0.8, z}, 0.6 + node.beat * 0.4, 8, 8, rl.WHITE)
		}
		if i % 5 == 0 {
			star_x := f32(((i * 73) % 31) - 15) * 1.6
			star_y := f32(((i * 47) % 17) - 3) * 1.2
			rl.DrawSphere({star_x, star_y, z}, 0.035 + node.high * 0.08, color)
		}
	}

	ship_x := player_lane * LANE_WIDTH
	ship_color := rl.ColorFromHSV(315 + pulse * 30, 0.65, 1)
	rl.DrawCylinderEx({ship_x, 0.25, -0.3}, {ship_x, 0.25, 1.6}, 0.38, 0.06, 8, ship_color)
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
		fmt.println("map: analyzing bass, mids, highs and transients...")
		nodes = analyze_file(path_c)
		if len(nodes) == 0 {
			fmt.eprintln("psycho: unsupported or invalid audio file")
			return
		}
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
	score, streak, best_streak: int
	paused, finished: bool
	pulse: f32
	for !rl.WindowShouldClose() {
		rl.UpdateMusicStream(music)
		dt := min(rl.GetFrameTime(), 0.05)
		if rl.IsKeyPressed(.SPACE) {
			paused = !paused
			if paused do rl.PauseMusicStream(music)
			else do rl.ResumeMusicStream(music)
		}
		if rl.IsKeyPressed(.B) && fx_channels >= 2 do fx_on = !fx_on
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
		move: f32
		if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) do move -= 1
		if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do move += 1
		player_lane = clamp(player_lane + move * dt * 2.2, -1, 1)

		time_played := rl.GetMusicTimePlayed(music)
		current := clamp(int(time_played / STEP), 0, len(nodes) - 1)
		if current > last_index {
			for i in last_index + 1 ..= current {
				if nodes[i].beat > 0 {
					if abs(player_lane - f32(nodes[i].lane)) < 0.43 {
						streak += 1
						score += int(100 * nodes[i].beat) * max(1, min(8, streak))
						best_streak = max(best_streak, streak)
						pulse = 1
						fx_tingle = 1
					} else {
						streak = 0
					}
				}
			}
			last_index = current
		}
		pulse = max(0, pulse - dt * 2.8)
		fx_tingle = max(0, fx_tingle - dt * 2.0)
		fx_beat_hz = 4.0 + f64(nodes[current].bass) * 6.0
		finished = current >= len(nodes) - 2 && !rl.IsMusicStreamPlaying(music)
		if finished && rl.IsKeyPressed(.R) {
			rl.SeekMusicStream(music, 0)
			rl.PlayMusicStream(music)
			last_index, score, streak = 0, 0, 0
			finished = false
		}

		w, h := rl.GetScreenWidth(), rl.GetScreenHeight()
		energy := nodes[current].bass * 0.6 + nodes[current].mid * 0.3 + nodes[current].high * 0.1
		bg := rl.Color{u8(4 + energy * 8), u8(3 + energy * 3), u8(14 + energy * 18), 255}
		rl.BeginDrawing()
		rl.ClearBackground(bg)
		rl.BeginBlendMode(.ADDITIVE)
		for ring in 0 ..< 5 {
			radius := f32(90 + ring * 95) + pulse * 30
			rl.DrawCircleLines(w / 2, h / 2, radius, rl.Color{30, u8(40 + ring * 25), 120, 70})
		}
		rl.EndBlendMode()
		draw_ride(nodes, current, player_lane, pulse)

		rl.DrawRectangle(22, 20, 390, 92, rl.Color{2, 4, 16, 205})
		rl.DrawText("PSYCHO", 36, 30, 32, rl.Color{255, 80, 210, 255})
		rl.DrawText(rl.TextFormat("SCORE %08d   STREAK x%d", score, streak), 36, 72, 20, rl.WHITE)
		progress := f32(current) / f32(max(1, len(nodes) - 1))
		rl.DrawRectangle(36, 98, 350, 4, rl.Color{30, 30, 55, 255})
		rl.DrawRectangle(36, 98, i32(350 * progress), 4, rl.Color{50, 220, 255, 255})
		fx_label: cstring = "EXPERIMENTAL FX: OFF [B]"
		if fx_channels < 2 do fx_label = "EXPERIMENTAL FX: NEEDS STEREO"
		if fx_on do fx_label = rl.TextFormat("EXPERIMENTAL FX: %.0f%% [B]", fx_amount * 100)
		rl.DrawText(fx_label, 24, h - 58, 17, rl.Color{150, 190, 225, 255})
		rl.DrawText(
			"A/D steer   SPACE pause   B binaural+tingle   [ ] effect   -/+ volume",
			24,
			h - 32,
			16,
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
