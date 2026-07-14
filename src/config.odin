package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

Game_Config :: struct {
	mouse_response:    f32,
	music_volume:      f32,
	visual_strength:   f32,
	audio_fx_strength: f32,
	speed_limit:       int,
	visual_fx:         bool,
	audio_fx:          bool,
	hide_cursor:       bool,
}

RESULTS_PATH :: ".games/results.tsv"

default_game_config :: proc() -> Game_Config {
	return {
		mouse_response = 26,
		music_volume = 0.65,
		visual_strength = 0.65,
		audio_fx_strength = 0.22,
		speed_limit = -1,
		visual_fx = true,
		audio_fx = false,
		hide_cursor = true,
	}
}

parse_game_config :: proc(text: string) -> Game_Config {
	config := default_game_config()
	remaining := text
	for raw_line in strings.split_lines_iterator(&remaining) {
		line := strings.trim_space(raw_line)
		if len(line) == 0 || line[0] == '#' || line[0] == '[' do continue
		if comment_at := strings.index_byte(line, '#'); comment_at >= 0 {
			line = strings.trim_space(line[:comment_at])
		}
		equals_at := strings.index_byte(line, '=')
		if equals_at <= 0 do continue
		key := strings.trim_space(line[:equals_at])
		value := strings.trim_space(line[equals_at + 1:])
		switch key {
		case "mouse_response":
			if parsed, ok := strconv.parse_f32(value); ok do config.mouse_response = parsed
		case "music_volume":
			if parsed, ok := strconv.parse_f32(value); ok do config.music_volume = parsed
		case "visual_strength":
			if parsed, ok := strconv.parse_f32(value); ok do config.visual_strength = parsed
		case "audio_fx_strength":
			if parsed, ok := strconv.parse_f32(value); ok do config.audio_fx_strength = parsed
		case "speed_limit":
			if parsed, ok := strconv.parse_int(value); ok do config.speed_limit = parsed
		case "visual_fx":
			if parsed, ok := strconv.parse_bool(value); ok do config.visual_fx = parsed
		case "audio_fx":
			if parsed, ok := strconv.parse_bool(value); ok do config.audio_fx = parsed
		case "hide_cursor":
			if parsed, ok := strconv.parse_bool(value); ok do config.hide_cursor = parsed
		}
	}
	config.mouse_response = clamp(config.mouse_response, 8, 60)
	config.music_volume = clamp(config.music_volume, 0, 0.8)
	config.visual_strength = clamp(config.visual_strength, 0, 1)
	config.audio_fx_strength = clamp(config.audio_fx_strength, 0, 0.5)
	if config.speed_limit < -1 do config.speed_limit = -1
	if config.speed_limit >= 0 {
		config.speed_limit = clamp(
			config.speed_limit,
			int(TRACK_MIN_SPEED_PERCENT),
			int(TRACK_MAX_SPEED_PERCENT),
		)
	}
	return config
}

load_game_config :: proc(path: string) -> Game_Config {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return default_game_config()
	defer delete(data)
	return parse_game_config(transmute(string)data)
}

format_game_result :: proc(
	completed_unix: i64,
	song: string,
	score, best_streak, crashes: int,
	duration_seconds: f32,
) -> string {
	return fmt.aprintf(
		"%d\t%q\t%d\t%d\t%d\t%.2f\n",
		completed_unix,
		song,
		score,
		best_streak,
		crashes,
		duration_seconds,
	)
}

save_game_result :: proc(
	song: string,
	score, best_streak, crashes: int,
	duration_seconds: f32,
) -> bool {
	if err := os.make_directory_all(".games"); err != nil && err != .Exist do return false
	file, err := os.open(RESULTS_PATH, {.Write, .Append, .Create}, os.Permissions_Default_File)
	if err != nil do return false
	existing_size, size_err := os.file_size(file)
	if size_err != nil {
		_ = os.close(file)
		return false
	}
	if existing_size == 0 {
		_, err = os.write_string(
			file,
			"completed_unix\tsong\tscore\tbest_streak\tcrashes\tduration_seconds\n",
		)
		if err != nil {
			_ = os.close(file)
			return false
		}
	}
	line := format_game_result(
		time.to_unix_seconds(time.now()),
		song,
		score,
		best_streak,
		crashes,
		duration_seconds,
	)
	defer delete(line)
	_, write_err := os.write_string(file, line)
	close_err := os.close(file)
	return write_err == nil && close_err == nil
}
