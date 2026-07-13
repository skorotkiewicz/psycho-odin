# PSYCHO

An audio-reactive puzzle racer in Odin and raylib. It analyzes song-relative
bass, mids, highs, dynamics, and transients, then turns them into a banked 3D
highway with speed changes, climbs, dives, traffic, hazards, and powerups.
Generated maps are cached by audio-content hash.

```sh
odin build . -out:psycho
./psycho music.wav
```

Raylib also accepts MP3, OGG, and FLAC. Cached maps live in `.psycho_cache/`;
changing the audio or analyzer version creates a new map automatically.

Collect same-color traffic to grow the chain multiplier, dodge red hazards,
and collect green shields. Three hull hits cause a crash and halve the score,
but the ride continues.

Controls: `A/D` or arrows steer, `Space` pauses, `F` toggles fullscreen,
`P` toggles the psychedelic post-process, `,`/`.` changes visual strength,
`B` toggles experimental binaural/spatial audio, `[`/`]` changes audio-effect
strength, and `-`/`+` changes volume. Stereo headphones are required for the
binaural effect.

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

```sh
./psycho --self-test
```
