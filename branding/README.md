# Marine Sensitivity brand set

One generator, every variant: `python3 make_branding.py` writes the SVGs, renders the PNGs and
rebuilds `favicon.ico` from the same vector. Nothing here is hand-maintained — the set is three
drawings (mark, lockup, hero) in light and dark, and the agency label is a string.

| file | use |
|---|---|
| `mst-mark.svg` / `-dark.svg`, `mst-mark-512.png`, `mst-mark-192.png` | the mark alone: favicons, app headers, avatars. Legible at 16 px, which is why it carries no creature. |
| `mst-logo.svg` / `-dark.svg` (+ `.png`) | mark + wordmark: docs headers, the Cloudflare Access login page, slides |
| `mst-hero.svg` / `-light.svg` (+ `.png`) | landing pages, docs covers, decks |
| `favicon.ico` | 16/32/48/64, generated from `mst-mark.svg` — sharper than the 2024 original |

**Served publicly** from `https://file.marinesensitivity.org/branding/…` (a `handle_path` in
`caddy/Caddyfile` points at this directory, so a `git pull` on the server publishes them; there is
no copy step to forget).

## What the drawing says

The mark is the original 2024 favicon redrawn as vector: a wave crossing a circle, the sea surface
inside the globe the toolkit maps. The hero adds the two things the toolkit actually does — the
band of squares riding the crest is the **0.05° cell grid** every distribution is resampled onto,
and the bar under the wordmark is **Spectral**, the exact ramp the score maps use — and the animals
being scored: a whale fluke breaking the surface, a sea turtle from above (the leatherback is the
species app's default taxon), and a school of fish.

Blue `#3AB2E4` is inherited from the original favicon; the ring is `#2F4858`.

## The agency label

The label under the wordmark is one environment variable. It defaults to `MMA` (the Marine Minerals
Administration, formerly the Bureau of Ocean Energy Management; the set read `BOEM` until
2026-11-12):

```sh
python3 make_branding.py             # TOOLKIT · MMA
AGENCY= python3 make_branding.py     # no agency line at all
```

Re-render and commit. The copies in `docs/images/` and `MarineSensitivity.github.io/images/` are
copied from here by hand, so refresh them in the same change.
