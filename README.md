# PSYCHO

An audio-reactive neon ride in Odin and raylib. It analyzes bass, mids, highs,
and transients, then caches the generated track by audio-content hash.

```sh
odin build . -out:psycho
./psycho music.wav
```

Raylib also accepts MP3, OGG, and FLAC. Cached maps live in `.psycho_cache/`;
changing the audio or analyzer version creates a new map automatically.

Controls: `A/D` or arrows steer, `Space` pauses, `B` toggles experimental
binaural/spatial-tingle audio, `[`/`]` changes its intensity, and `-`/`+`
changes volume. Stereo headphones are required for the binaural effect.

The audio layer is entertainment, not treatment. Research does not establish
one best binaural frequency, and outcomes are mixed and protocol-dependent.
ASMR relaxation/tingles also occur only for some listeners. Keep volume low;
the WHO recommends staying below an average 80 dB and limiting exposure.

- Binaural-beat systematic review: https://pubmed.ncbi.nlm.nih.gov/37205669/
- ASMR physiology study: https://pmc.ncbi.nlm.nih.gov/articles/PMC6010208/
- WHO safe listening: https://www.who.int/news-room/questions-and-answers/item/deafness-and-hearing-loss-safe-listening

```sh
./psycho --self-test
```
