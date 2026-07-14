package main

import "core:math"
import "core:sync"

AUDIO_FX_MAX_AMOUNT :: f32(0.5)
AUDIO_FX_MIN_BEAT_HZ :: f32(4)
AUDIO_FX_MAX_BEAT_HZ :: f32(10)
AUDIO_FX_DEFAULT_BEAT_HZ :: f32(7)
AUDIO_FX_WET_RAMP_SECONDS :: f32(0.030)
AUDIO_FX_AMOUNT_RAMP_SECONDS :: f32(0.040)
AUDIO_FX_BEAT_RAMP_SECONDS :: f32(0.040)
AUDIO_FX_DELAY_SECONDS :: f32(0.0175)
AUDIO_FX_TINGLE_DECAY_PER_SECOND :: f32(2)
AUDIO_FX_NOISE_SEED :: u32(0x91e10da5)
AUDIO_FX_DELAY_CAPACITY :: 4096

Audio_FX_Controls :: struct {
	enabled:      bool,
	amount:       f32,
	beat_hz:      f32,
	tingle_event: u32,
	reset_event:  u32,
}

// This state is owned by the audio thread after the processor is attached.
Audio_FX_State :: struct {
	wet:               f32,
	amount:            f32,
	beat_hz:           f32,
	tingle:            f32,
	phase_l:           f64,
	phase_r:           f64,
	pan_phase:         f64,
	noise:             u32,
	soft_noise:        f32,
	delay:             [AUDIO_FX_DELAY_CAPACITY][2]f32,
	delay_at:          int,
	last_tingle_event: u32,
	last_reset_event:  u32,
}

// The game thread publishes controls as atomic scalar targets. The callback
// snapshots them once per buffer and smooths every audible change itself.
fx_target_enabled: u32
fx_target_amount_bits: u32
fx_target_beat_hz_bits: u32
fx_tingle_events: u32
fx_reset_events: u32
fx_sample_rate: f32 = 48000
fx_channel_count: int = 2
fx_audio_state: Audio_FX_State

audio_fx_reset_state :: proc "contextless" (state: ^Audio_FX_State) {
	state^ = {}
	state.beat_hz = AUDIO_FX_DEFAULT_BEAT_HZ
	state.noise = AUDIO_FX_NOISE_SEED
}

audio_fx_store_f32 :: proc "contextless" (target: ^u32, value: f32) {
	sync.atomic_store_explicit(target, transmute(u32)value, .Release)
}

audio_fx_load_f32 :: proc "contextless" (target: ^u32) -> f32 {
	return transmute(f32)sync.atomic_load_explicit(target, .Acquire)
}

audio_fx_set_enabled :: proc(enabled: bool) {
	sync.atomic_store_explicit(&fx_target_enabled, u32(1) if enabled else 0, .Release)
}

audio_fx_set_amount :: proc(amount: f32) {
	audio_fx_store_f32(&fx_target_amount_bits, clamp(amount, 0, AUDIO_FX_MAX_AMOUNT))
}

audio_fx_set_beat_hz :: proc(beat_hz: f32) {
	audio_fx_store_f32(
		&fx_target_beat_hz_bits,
		clamp(beat_hz, AUDIO_FX_MIN_BEAT_HZ, AUDIO_FX_MAX_BEAT_HZ),
	)
}

audio_fx_trigger_tingle :: proc() {
	sync.atomic_add_explicit(&fx_tingle_events, u32(1), .Release)
}

audio_fx_request_reset :: proc() {
	sync.atomic_add_explicit(&fx_reset_events, u32(1), .Release)
}

audio_fx_initialize :: proc(enabled: bool, amount, sample_rate: f32, channel_count: int) {
	fx_sample_rate = max(1, sample_rate)
	fx_channel_count = channel_count
	audio_fx_reset_state(&fx_audio_state)
	sync.atomic_store_explicit(&fx_tingle_events, u32(0), .Release)
	sync.atomic_store_explicit(&fx_reset_events, u32(0), .Release)
	audio_fx_set_enabled(enabled)
	audio_fx_set_amount(amount)
	audio_fx_set_beat_hz(AUDIO_FX_DEFAULT_BEAT_HZ)
}

audio_fx_controls_snapshot :: proc "contextless" () -> Audio_FX_Controls {
	return {
		enabled = sync.atomic_load_explicit(&fx_target_enabled, .Acquire) != 0,
		amount = audio_fx_load_f32(&fx_target_amount_bits),
		beat_hz = audio_fx_load_f32(&fx_target_beat_hz_bits),
		tingle_event = sync.atomic_load_explicit(&fx_tingle_events, .Acquire),
		reset_event = sync.atomic_load_explicit(&fx_reset_events, .Acquire),
	}
}

audio_fx_approach :: proc "contextless" (current, target, max_step: f32) -> f32 {
	if current < target do return min(current + max_step, target)
	return max(current - max_step, target)
}

audio_fx_delay_samples :: proc "contextless" (sample_rate: f32) -> int {
	return clamp(int(sample_rate * AUDIO_FX_DELAY_SECONDS + 0.5), 1, AUDIO_FX_DELAY_CAPACITY - 1)
}

audio_fx_process :: proc "contextless" (
	samples: [^]f32,
	frames, channel_count: int,
	sample_rate: f32,
	controls: Audio_FX_Controls,
	state: ^Audio_FX_State,
) {
	if frames <= 0 || channel_count < 2 || sample_rate <= 0 do return

	tau := 2.0 * math.PI
	wet_step := 1 / (sample_rate * AUDIO_FX_WET_RAMP_SECONDS)
	amount_step := AUDIO_FX_MAX_AMOUNT / (sample_rate * AUDIO_FX_AMOUNT_RAMP_SECONDS)
	beat_step :=
		(AUDIO_FX_MAX_BEAT_HZ - AUDIO_FX_MIN_BEAT_HZ) / (sample_rate * AUDIO_FX_BEAT_RAMP_SECONDS)
	tingle_step := AUDIO_FX_TINGLE_DECAY_PER_SECOND / sample_rate
	noise_step := clamp(0.035 * 48000 / sample_rate, 0, 1)
	delay_samples := audio_fx_delay_samples(sample_rate)
	target_wet: f32
	if controls.enabled do target_wet = 1
	target_amount := clamp(controls.amount, 0, AUDIO_FX_MAX_AMOUNT)
	target_beat_hz := clamp(controls.beat_hz, AUDIO_FX_MIN_BEAT_HZ, AUDIO_FX_MAX_BEAT_HZ)
	if controls.reset_event != state.last_reset_event {
		reset_event := controls.reset_event
		tingle_event := controls.tingle_event
		audio_fx_reset_state(state)
		state.last_reset_event = reset_event
		state.last_tingle_event = tingle_event
	}
	if controls.tingle_event != state.last_tingle_event {
		state.last_tingle_event = controls.tingle_event
		state.tingle = 1
	}

	for frame in 0 ..< frames {
		state.wet = audio_fx_approach(state.wet, target_wet, wet_step)
		state.amount = audio_fx_approach(state.amount, target_amount, amount_step)
		state.beat_hz = audio_fx_approach(state.beat_hz, target_beat_hz, beat_step)
		state.tingle = max(0, state.tingle - tingle_step)

		state.phase_l += tau * 180.0 / f64(sample_rate)
		state.phase_r += tau * (180.0 + f64(state.beat_hz)) / f64(sample_rate)
		state.pan_phase += tau * 0.13 / f64(sample_rate)
		if state.phase_l > tau do state.phase_l -= tau
		if state.phase_r > tau do state.phase_r -= tau
		if state.pan_phase > tau do state.pan_phase -= tau

		state.noise ~= state.noise << 13
		state.noise ~= state.noise >> 17
		state.noise ~= state.noise << 5
		white := f32(state.noise & 0xffff) / 32767.5 - 1
		state.soft_noise += (white - state.soft_noise) * noise_step

		dry_l := samples[frame * channel_count]
		dry_r := samples[frame * channel_count + 1]
		delayed := (state.delay_at + len(state.delay) - delay_samples) % len(state.delay)
		state.delay[state.delay_at] = {dry_l, dry_r}
		state.delay_at = (state.delay_at + 1) % len(state.delay)

		strength := state.wet * state.amount
		if strength <= 0 do continue

		pan := f32(math.sin(state.pan_phase))
		breath := state.soft_noise * (0.004 + state.tingle * 0.008) * strength
		tone := strength * 0.025
		width := strength * 0.055
		dry_gain := 1 - strength * 0.11
		left :=
			dry_l * dry_gain +
			f32(math.sin(state.phase_l)) * tone +
			breath * (1 - pan) +
			state.delay[delayed][1] * width
		right :=
			dry_r * dry_gain +
			f32(math.sin(state.phase_r)) * tone +
			breath * (1 + pan) +
			state.delay[delayed][0] * width
		samples[frame * channel_count] = clamp(left, -1, 1)
		samples[frame * channel_count + 1] = clamp(right, -1, 1)
	}
}

audio_fx :: proc "c" (buffer_data: rawptr, frames: u32) {
	if fx_channel_count < 2 do return
	audio_fx_process(
		cast([^]f32)buffer_data,
		int(frames),
		fx_channel_count,
		fx_sample_rate,
		audio_fx_controls_snapshot(),
		&fx_audio_state,
	)
}

audio_fx_self_test :: proc() {
	audio_fx_initialize(true, 0.31, 44100, 2)
	control_snapshot := audio_fx_controls_snapshot()
	assert(control_snapshot.enabled)
	assert(abs(control_snapshot.amount - 0.31) < 0.001)
	assert(control_snapshot.beat_hz == AUDIO_FX_DEFAULT_BEAT_HZ)
	audio_fx_set_enabled(false)
	audio_fx_set_amount(2)
	audio_fx_set_beat_hz(100)
	audio_fx_trigger_tingle()
	audio_fx_request_reset()
	control_snapshot = audio_fx_controls_snapshot()
	assert(!control_snapshot.enabled)
	assert(control_snapshot.amount == AUDIO_FX_MAX_AMOUNT)
	assert(control_snapshot.beat_hz == AUDIO_FX_MAX_BEAT_HZ)
	assert(control_snapshot.tingle_event == 1 && control_snapshot.reset_event == 1)

	assert(audio_fx_delay_samples(44100) == 772)
	assert(audio_fx_delay_samples(48000) == 840)
	assert(audio_fx_delay_samples(96000) == 1680)
	assert(audio_fx_delay_samples(384000) == AUDIO_FX_DELAY_CAPACITY - 1)

	frames := 4096
	buffer := make([]f32, frames * 2)
	original := make([]f32, len(buffer))
	defer delete(buffer)
	defer delete(original)
	state: Audio_FX_State
	controls := Audio_FX_Controls {
		enabled = true,
		amount  = 0,
		beat_hz = AUDIO_FX_DEFAULT_BEAT_HZ,
	}

	// Zero strength must be a bit-exact dry path, including the tingle layer.
	for i in 0 ..< len(buffer) do buffer[i] = f32(i % 17 - 8) / 10
	copy(original, buffer)
	audio_fx_reset_state(&state)
	controls.tingle_event = 1
	audio_fx_process(raw_data(buffer), frames, 2, 48000, controls, &state)
	for i in 0 ..< len(buffer) do assert(buffer[i] == original[i])
	assert(state.tingle > 0, "tingle events must reach the audio-thread envelope")

	// Disabled processing must still feed its history without touching samples.
	audio_fx_reset_state(&state)
	controls.enabled = false
	controls.amount = AUDIO_FX_MAX_AMOUNT
	controls.tingle_event = 0
	audio_fx_process(raw_data(buffer), frames, 2, 48000, controls, &state)
	for i in 0 ..< len(buffer) do assert(buffer[i] == original[i])
	assert(
		state.delay[17][0] == original[34] && state.delay[17][1] == original[35],
		"the dry path must keep delay history current",
	)
	reset_frame := [2]f32{}
	controls.reset_event = 1
	audio_fx_process(cast([^]f32)&reset_frame[0], 1, 2, 48000, controls, &state)
	assert(state.last_reset_event == 1)
	assert(
		state.delay[17][0] == 0 && state.delay[17][1] == 0,
		"a restarted ride must clear stale delay history on the audio thread",
	)
	controls.reset_event = 0

	// A full-strength fade-in must become stereo, remain finite, and keep headroom.
	for &sample in buffer do sample = 0.99
	audio_fx_reset_state(&state)
	controls.enabled = true
	controls.amount = AUDIO_FX_MAX_AMOUNT
	controls.beat_hz = AUDIO_FX_MAX_BEAT_HZ
	audio_fx_process(raw_data(buffer), frames, 2, 48000, controls, &state)
	assert(state.wet == 1 && state.amount == AUDIO_FX_MAX_AMOUNT)
	assert(abs(state.beat_hz - AUDIO_FX_MAX_BEAT_HZ) < 0.001)
	max_sample, stereo_difference: f32
	for frame in 0 ..< frames {
		left := buffer[frame * 2]
		right := buffer[frame * 2 + 1]
		assert(!math.is_nan(left) && !math.is_nan(right))
		max_sample = max(max_sample, max(abs(left), abs(right)))
		stereo_difference += abs(left - right)
	}
	assert(max_sample < 1, "the effect must preserve headroom on mastered audio")
	assert(stereo_difference > 0.1, "the binaural layer must create a stereo difference")

	// Turning the wet path off must cross the buffer boundary without a step,
	// then settle back to a bit-exact dry path within its documented ramp.
	for &sample in buffer do sample = 0
	audio_fx_reset_state(&state)
	controls.enabled = true
	audio_fx_process(raw_data(buffer), frames, 2, 48000, controls, &state)
	last_left := buffer[len(buffer) - 2]
	for &sample in buffer do sample = 0
	controls.enabled = false
	audio_fx_process(raw_data(buffer), frames, 2, 48000, controls, &state)
	assert(abs(buffer[0] - last_left) < 0.01, "audio FX toggles must not click")
	assert(state.wet == 0)
	for i in len(buffer) - 128 ..< len(buffer) do assert(buffer[i] == 0)

	// Channels beyond left/right are never repurposed by the stereo processor.
	surround := [4]f32{0.1, -0.2, 0.3, -0.4}
	audio_fx_reset_state(&state)
	controls.enabled = true
	audio_fx_process(cast([^]f32)&surround[0], 1, 4, 48000, controls, &state)
	assert(surround[2] == 0.3 && surround[3] == -0.4)
}
