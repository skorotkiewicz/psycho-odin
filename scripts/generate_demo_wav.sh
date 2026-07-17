#!/usr/bin/env bash
set -euo pipefail

# Generate a deliberately synthetic PSYCHO showcase track.
#
# The analyzer emits one node every 0.1 seconds and groups 64 nodes into a
# movement, so the first four blocks are 6.4 seconds. The final block fills the
# remaining 4.4 seconds of the requested 30-second WAV.
#
#   00.0-06.4  quiet 100 Hz             -> CLIMB
#   06.4-12.8  pulsed 80 Hz bass         -> DROP
#   12.8-19.2  pulsed 800 Hz mids        -> SPIRAL
#   19.2-25.6  fast pulsed 650 Hz mids   -> recovery SLALOM
#   25.6-30.0  fast pulsed 3200 Hz highs -> TUNNEL

output=${1:-demo.wav}
sample_rate=48000

if ! command -v ffmpeg >/dev/null 2>&1; then
	printf 'error: ffmpeg is required\n' >&2
	exit 1
fi

ffmpeg -hide_banner -loglevel error -y \
	-f lavfi -i "aevalsrc=0.018*sin(2*PI*100*t):s=${sample_rate}:d=6.4" \
	-f lavfi -i "aevalsrc=0.30*(0.42+0.58*lt(mod(t\,0.50)\,0.08))*sin(2*PI*80*t):s=${sample_rate}:d=6.4" \
	-f lavfi -i "aevalsrc=0.26*(0.40+0.60*lt(mod(t\,0.40)\,0.07))*sin(2*PI*800*t):s=${sample_rate}:d=6.4" \
	-f lavfi -i "aevalsrc=0.20*(0.35+0.65*lt(mod(t\,0.30)\,0.06))*sin(2*PI*650*t):s=${sample_rate}:d=6.4" \
	-f lavfi -i "aevalsrc=0.24*(0.32+0.68*lt(mod(t\,0.30)\,0.06))*sin(2*PI*3200*t):s=${sample_rate}:d=4.4" \
	-filter_complex \
		"[0:a]afade=t=in:st=0:d=0.02,afade=t=out:st=6.38:d=0.02[s0]; \
		 [1:a]afade=t=in:st=0:d=0.02,afade=t=out:st=6.38:d=0.02[s1]; \
		 [2:a]afade=t=in:st=0:d=0.02,afade=t=out:st=6.38:d=0.02[s2]; \
		 [3:a]afade=t=in:st=0:d=0.02,afade=t=out:st=6.38:d=0.02[s3]; \
		 [4:a]afade=t=in:st=0:d=0.02,afade=t=out:st=4.38:d=0.02[s4]; \
		 [s0][s1][s2][s3][s4]concat=n=5:v=0:a=1,pan=stereo|c0=c0|c1=c0[out]" \
	-map '[out]' \
	-t 30 \
	-ar "${sample_rate}" \
	-c:a pcm_s16le \
	-metadata title='PSYCHO movement showcase' \
	"${output}"

printf 'generated %s (30 s, 48 kHz, stereo PCM WAV)\n' "${output}"
printf 'try: ./psycho --analyze %q\n' "${output}"
printf 'ride: ./psycho %q\n' "${output}"
