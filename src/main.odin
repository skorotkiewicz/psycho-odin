package main

import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

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

	config := load_game_config("config.toml")
	audio_path := os.args[1]
	if analyze_only do audio_path = os.args[2]
	file_bytes, file_err := os.read_entire_file(audio_path, context.allocator)
	if file_err != nil {
		fmt.eprintfln("psycho: cannot read %q: %v", audio_path, file_err)
		return
	}
	map_path := cache_path(file_bytes, config.speed_limit)
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
		nodes = analyze_file(path_c, config.speed_limit)
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
	rl.SetWindowMinSize(800, 600)
	cursor_hidden := false
	if config.hide_cursor {
		rl.HideCursor()
		cursor_hidden = true
	}
	defer {
		if cursor_hidden do rl.ShowCursor()
	}
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
	music.looping = false
	music_duration := rl.GetMusicTimeLength(music)
	volume := config.music_volume
	rl.SetMusicVolume(music, volume)
	fx_on = config.audio_fx
	fx_amount = config.audio_fx_strength
	fx_rate = f64(music.sampleRate)
	fx_channels = int(music.channels)
	if fx_channels >= 2 {
		rl.AttachAudioStreamProcessor(music.stream, audio_fx)
		defer rl.DetachAudioStreamProcessor(music.stream, audio_fx)
	}
	rl.PlayMusicStream(music)
	playback_seen := rl.IsMusicStreamPlaying(music)
	song_name_c := strings.clone_to_cstring(os.base(audio_path), context.temp_allocator)

	player_lane, steer_lean: f32
	mouse_active := false
	last_index := 0
	score, streak, best_streak, color_chain, crashes: int
	last_tone: i32
	last_tone = -1
	shield := 3
	paused, finished: bool
	results_saved, result_save_ok: bool
	visual_fx := config.visual_fx
	visual_amount := config.visual_strength
	pulse, shake, overdrive: f32
	rhythm_push: Rhythm_Push
	for !rl.WindowShouldClose() {
		rl.UpdateMusicStream(music)
		dt := min(rl.GetFrameTime(), 0.05)
		if !finished && rl.IsKeyPressed(.SPACE) {
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
		if ride_controls_enabled(paused, finished) {
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
				player_lane = smooth_mouse_lane(
					player_lane,
					target_lane,
					dt,
					config.mouse_response,
				)
			}
			lane_speed := (player_lane - lane_before_input) / max(0.001, dt)
			target_lean := clamp(lane_speed * 0.28, -1, 1)
			steer_lean += (target_lean - steer_lean) * min(1, dt * 9)
		} else {
			mouse_active = false
		}

		time_played := rl.GetMusicTimePlayed(music)
		node_time := time_played / STEP
		current := clamp(int(node_time), 0, len(nodes) - 1)
		fraction := clamp(node_time - f32(current), 0, 1)
		rhythm_impulse: f32
		if current > last_index {
			for i in last_index + 1 ..= current {
				node := nodes[i]
				rhythm_impulse = max(
					rhythm_impulse,
					rhythm_impulse_strength(max(node.onset, node.beat), node.bass, visual_amount),
				)
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
					outcome := resolve_hazard(
						shield,
						score,
						streak,
						color_chain,
						last_tone,
						crashes,
						overdrive,
					)
					shield, score, streak = outcome.shield, outcome.score, outcome.streak
					color_chain, last_tone, crashes =
						outcome.color_chain, outcome.last_tone, outcome.crashes
					if outcome.blocked do pulse, fx_tingle = 1, 1
					else do shake, pulse = 1, 1
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
		rhythm_push = rhythm_push_step(
			rhythm_push,
			rhythm_impulse,
			dt,
			ride_controls_enabled(paused, finished),
		)
		pulse = max(0, pulse - dt * 2.8)
		shake = max(0, shake - dt * 4.5)
		overdrive = max(0, overdrive - dt)
		fx_tingle = max(0, fx_tingle - dt * 2.0)
		fx_beat_hz = 4.0 + f64(nodes[current].bass) * 6.0
		music_playing := rl.IsMusicStreamPlaying(music)
		if music_playing do playback_seen = true
		finished = ride_finished(paused, playback_seen, music_playing)
		if finished && !results_saved {
			result_save_ok = save_game_result(
				audio_path,
				score,
				best_streak,
				crashes,
				music_duration,
			)
			results_saved = true
			if result_save_ok do fmt.printfln("result: saved %s", RESULTS_PATH)
			else do fmt.eprintfln("result: could not save %s", RESULTS_PATH)
		}
		if finished && rl.IsKeyPressed(.R) {
			rl.SeekMusicStream(music, 0)
			rl.PlayMusicStream(music)
			playback_seen = rl.IsMusicStreamPlaying(music)
			last_index, score, streak, best_streak, color_chain, last_tone, crashes =
				0, 0, 0, 0, 0, -1, 0
			shield = 3
			overdrive = 0
			rhythm_push = {}
			finished = false
			results_saved, result_save_ok = false, false
		}
		should_hide_cursor := config.hide_cursor && !paused && !finished
		if should_hide_cursor && !cursor_hidden {
			rl.HideCursor()
			cursor_hidden = true
		} else if !should_hide_cursor && cursor_hidden {
			rl.ShowCursor()
			cursor_hidden = false
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
		rhythm := Rhythm_Motion {
			kick = rhythm_kick_response(
				max(nodes[current].onset, nodes[current].beat),
				nodes[current].bass,
				fraction,
				visual_amount,
			),
			push = rhythm_push,
		}
		rl.BeginTextureMode(scene)
		rl.ClearBackground(rl.BLACK)
		draw_music_background(
			scene.texture.width,
			scene.texture.height,
			time_played,
			nodes[current].bass,
			nodes[current].mid,
			nodes[current].high,
			nodes[current].onset * (1 - fraction),
			pace_now,
			pulse,
			visual_amount,
		)
		draw_ride(nodes, current, fraction, player_lane, steer_lean, pulse, shake, rhythm)
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
				track_speed_percent(pace_now, config.speed_limit),
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
			panel_width := min(650, w - 40)
			panel_height := min(330, h - 40)
			panel_x := (w - panel_width) / 2
			panel_y := (h - panel_height) / 2
			rl.DrawRectangle(panel_x, panel_y, panel_width, panel_height, rl.Color{3, 5, 20, 242})
			rl.DrawRectangleLines(
				panel_x,
				panel_y,
				panel_width,
				panel_height,
				rl.Color{75, 220, 255, 220},
			)
			title: cstring = "RIDE COMPLETE"
			rl.DrawText(
				title,
				w / 2 - rl.MeasureText(title, 44) / 2,
				panel_y + 28,
				44,
				rl.Color{255, 90, 220, 255},
			)
			song_label := rl.TextFormat("FULL LOOP  //  %s", song_name_c)
			rl.DrawText(
				song_label,
				w / 2 - rl.MeasureText(song_label, 18) / 2,
				panel_y + 82,
				18,
				rl.Color{130, 220, 255, 255},
			)
			score_label := rl.TextFormat("SCORE  %08d", score)
			rl.DrawText(
				score_label,
				w / 2 - rl.MeasureText(score_label, 32) / 2,
				panel_y + 124,
				32,
				rl.WHITE,
			)
			rl.DrawText(
				rl.TextFormat(
					"BEST STREAK  %d     CRASHES  %d     TIME  %02d:%02d",
					best_streak,
					crashes,
					int(music_duration) / 60,
					int(music_duration) % 60,
				),
				panel_x + 36,
				panel_y + 176,
				20,
				rl.Color{210, 220, 245, 255},
			)
			save_label: cstring = "RESULT SAVE FAILED"
			save_color := rl.Color{255, 90, 105, 255}
			if result_save_ok {
				save_label = "RESULT SAVED  //  .games/results.tsv"
				save_color = rl.Color{80, 255, 160, 255}
			}
			rl.DrawText(
				save_label,
				w / 2 - rl.MeasureText(save_label, 17) / 2,
				panel_y + 222,
				17,
				save_color,
			)
			rl.DrawText(
				"PRESS R TO RIDE AGAIN",
				w / 2 - rl.MeasureText("PRESS R TO RIDE AGAIN", 20) / 2,
				panel_y + 267,
				20,
				rl.Color{130, 220, 255, 255},
			)
		}
		rl.EndDrawing()
	}
}
