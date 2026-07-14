# PSYCHO

An audio-reactive puzzle racer in Odin and raylib. It analyzes song-relative
bass, mids, highs, robust dynamic range, adaptive transients, local beat density,
and tempo confidence, then composes six-second musical movements: quiet climbs,
bass-heavy drops, mid-driven slaloms, and treble tunnels. Each has distinct
curves, banking, width, speed, traffic choreography, gates, portals, scenery,
hazards, boosts, and powerups.
Generated maps are cached by audio-content hash.

Every tenth of a second, local song-relative energy and onset density become a
`pace` value, with local tempo separating fast rhythmic passages from equally
loud sustained ones. Pace controls grade, world distance, camera energy, trail
length, and palette heat: calm music climbs slowly in cool colors, while
busy/intense music crests into a hot, fast descent. The HUD profile previews the
whole rollercoaster and marks the live song position. Its second view shows the
entire cached route from above. The cache stores a true 3D centerline and
heading/pitch, so road edges, traffic, banking, and the chase camera follow
sweeping left/right turns instead of skewing a straight strip. Each song is one
closed lap: the final cached position and tangent reconnect to the exact start,
then playback finishes normally. Movement labels control turn style and visual
character, never override the rhythm.

```sh
odin build src -out:psycho
./psycho music.wav
./psycho --analyze music.wav # optional: fill the cache without opening a window
```

Raylib also accepts MP3, OGG, and FLAC. Cached maps live in `.psycho_cache/`;
changing the audio or analyzer version creates a new map automatically.

Collect same-color traffic to grow the chain multiplier, dodge red hazards,
and collect green shields. Three hull hits cause a crash and halve the score,
but the ride continues. Gold cubes trigger six seconds of double-score
overdrive and stronger visual effects.

Controls: move the mouse horizontally, or use `A/D` or arrows, to steer. The
most recently used device takes control, so switching is seamless. `Space`
pauses, `F` toggles fullscreen, `P` toggles the psychedelic post-process,
`,`/`.` changes visual strength, `B` toggles binaural/spatial
audio, `[`/`]` changes audio-effect strength, and `-`/`+` changes volume.
The cursor is hidden during a live ride and shown while paused or on the result
screen. Stereo headphones are required for the binaural effect.

Startup defaults live in `config.toml`: mouse response, cursor hiding, music
volume, visual FX/strength, and binaural audio FX/strength. Completed rides
show score, best streak, and crashes, then append one timestamped record to
`.games/results.tsv`. Press `R` from the result screen to start a fresh run.

The audio layer is entertainment, not treatment. Research does not establish
one best binaural frequency, and outcomes are mixed and protocol-dependent.
ASMR relaxation/tingles also occur only for some listeners. Keep volume low;
the WHO recommends staying below an average 80 dB and limiting exposure.
The visual effect uses distortion and color separation rather than rapid
full-screen flashes; disable it with `P` if you experience discomfort.

- Binaural-beat systematic review: https://pubmed.ncbi.nlm.nih.gov/37205669/
- ASMR physiology study: https://pmc.ncbi.nlm.nih.gov/articles/PMC6010208/
- WHO safe listening: https://www.who.int/news-room/questions-and-answers/item/deafness-and-hearing-loss-safe-listening
- W3C flash-safety guidance: https://www.w3.org/WAI/WCAG22/Understanding/three-flashes-or-below-threshold.html

The level rules follow AudioSurf's documented high-level design: the song
determines track shape, speed, mood, and traffic; quieter sections climb and
slow down while intense sections dive and accelerate. PSYCHO uses its own
filter-bank analyzer, continuous steering, chain scoring, hazards, and effects.

- AudioSurf's official gameplay description: https://store.steampowered.com/app/12900/AudioSurf/
- Dylan Fitterer interview on hills and traffic: https://arstechnica.com/gaming/2008/03/catching-waveforms-audiosurf-creator-dylan-speaks/
- AudioSurf review documenting slow/uphill and fast/downhill mapping: https://www.gamespot.com/reviews/audiosurf-review/1900-6189185/

```sh
./psycho --self-test
```
