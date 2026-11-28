# Video layout contract (v1)

Rendering policy for short-form video on iPhone and iPad, and the `ar` field that
carries each item's aspect ratio from the catalog to the client.

Status: agreed 2026-11-28. Owner: server (contract) + iOS client (rendering).

## Surfaces covered

One mode per item, resolved once from `ar`, applied to **every** surface that
draws that item:

| Surface | Type | Same mode required |
|---|---|---|
| Feed video | `AVPlayerLayer.videoGravity` | yes |
| Cover image (pre-first-frame) | `UIImageView.contentMode` | yes, same layer geometry |
| Image / 图文 gallery slides | `UIImageView.contentMode` | yes (per post; per slide when known) |
| Live-photo / motion layer | `AVPlayerLayer.videoGravity` | yes |

The cover must carry the item's mode **before** the first video frame is
attached. Cross-fading only animates `alpha`; it never changes scale, content
mode or clipping. A cover laid out with a different mode than its video is the
main source of the visible scale jump on iPad.

## Decision

Both platforms are portrait-locked (`UISupportedInterfaceOrientations` and
`UISupportedInterfaceOrientations~ipad` are `UIInterfaceOrientationPortrait`
only), so the canvas never rotates. iPad therefore always lays out inside a 3:4
portrait canvas (aspect 0.75); the iPhone canvas is ≈0.46.

One rule, applied per item:

```
fill  ⟺  ar < 1        // 竖内容铺满，接受裁切
otherwise                 // 横、方内容：AVPlayerLayer 默认 .resizeAspect，留黑
```

```swift
let mode = MediaContentMode.resolve(aspectRatio: ar)   // .fill when ar < 1
playerLayer.videoGravity = mode.videoGravity            // .resizeAspectFill / .resizeAspect
coverImageView.contentMode = mode.imageContentMode      // .scaleAspectFill / .scaleAspectFit
hostView.clipsToBounds = mode.clipsContent             // clip only when filling
```

Landscape and square content get **no** special treatment: no blurred backdrop,
no first-frame capture, no re-framing. Letterboxing is accepted as-is.

## Crop cost on iPad (canvas 0.75)

| Content | Share of catalog | Gravity | Loss on iPad |
|---|---|---|---|
| 9:16 (0.5625) | 32% of catalog items | fill | **25% of height** |
| 4:5 (0.80) | — | fill | 6% of width |
| 1:1 | 2.7% | fit | 25% letterbox |
| 16:9 (1.78) | 65% | fit | 58% letterbox |

iPhone (canvas 0.46) is unaffected in practice: 9:16 fills almost exactly,
landscape letterboxes as before.

## Data contract

`ar` = `round(width / height, 2)`, computed server-side from the crawl archive.
It is optional on both files; a missing value means "unknown" and the client must
fall back to `.resizeAspect` / `.scaleAspectFit`.

**Image / 图文 posts never carry a manifest-level `ar`.** The list API reports a
constant `720x720` for them, which is a placeholder, not geometry — emitting it
would make every image post look square and crop vertical ones. Until the post is
resolved they render as `.fit`.

Geometry for an image post comes per slide, from the in-app slim detail:
`aweme_detail.images[i]` carries real `width`/`height` (verified against live posts, mixed orientations
inside one post are common), so each slide is emitted as

```json
{"id": "0", "image_url": "...", "video_url": "...", "width": 1279, "height": 1706, "ar": 0.75}
```

`ar` on a slide has the same meaning as the item-level field and drives that
slide's `MediaContentMode` — the cover, the slide image and its Live Photo layer
all take it from the slide, not from the post. A slide without `ar` (dimensions
missing upstream) inherits `.fit`.

`data/catalog.jsonl`, one line per author:

```json
{"uid": "...", "nick": "...", "videos": {"<aweme_id>": {"title": "...", "desc": "...", "ar": 0.56}}}
```

`GET /manifest.json`:

```json
{"schemaVersion": 1, "items": [{"id": "<aweme_id>", "title": "...", "ar": 0.56}]}
```

`schemaVersion` stays `1`: the field is additive and older clients must ignore
it. When `ar` is absent the app falls back to the `width`/`height` of its in-app
slim-detail response; the old `GET /resolve/{aweme_id}` no longer exists.

Cost: 28,288 items × ~9 bytes ≈ **+270 KB** on a 6.8 MB manifest.

## Producer change points

The FastAPI app is gone; the manifest is built offline and served by Caddy.

1. `tools/build_catalog.py` — write `ar` next to `title`/`desc`.
2. `tools/build_manifest.py` — pass `ar` through (drop unknown values) when it
   renders `public/manifest.json`.

## Client contract

- One `MediaContentMode` per item (`ar < 1 → .fill`) is resolved once and applied
  to every surface of that item: player layer gravity, cover `contentMode`,
  gallery cell `contentMode`, live-photo gravity.
- Each host view sets `clipsToBounds = mode.clipsContent`, i.e. it clips exactly
  when the mode fills.
- The cover carries the mode before the first frame is attached; the cross-fade
  animates `alpha` only.
- One `AVPlayer` instance per feed slot survives size changes (Split View,
  Stage Manager). Only the layer's `frame` and `videoGravity` update; never
  rebuild the player on layout change.
- To bias the crop upward (keep faces), enlarge the layer and offset its
  `position` inside a clipping parent. `AVPlayerLayer.contentsRect` is read-only
  and must not be used.
- Do not branch on `userInterfaceIdiom`. Geometry and `ar` are the only inputs;
  an iPad in Split View reports the same size classes as an iPhone in portrait.

## Out of scope

- Landscape canvas handling (portrait lock is a product decision).
- Blurred backdrops, first-frame extraction or cover images for landscape items.
- Per-item art-direction/crop keyframing (`AVVideoComposition`).

## Test matrix

| # | Canvas | Content | Expectation |
|---|---|---|---|
| 1 | iPhone 竖 | 9:16 | 铺满，无可见裁切 |
| 2 | iPhone 竖 | 16:9 | 上下留黑，画面完整 |
| 3 | iPad 竖 | 9:16 | 铺满，上下各裁 ~12.5% |
| 4 | iPad 竖 | 16:9 | 大幅留黑，画面完整 |
| 5 | iPad Split 1/2 (0.66) | 9:16 | 铺满，裁 ~15% |
| 6 | iPad 竖 | 1:1 | 上下留黑 25% |

Snapshot all six in CI; assert on `videoGravity`, not on pixels.

## Rollout

1. The catalog builder writes `ar`; `build_manifest.py` passes it through. Old
   clients ignore it.
2. The client reads `ar`; when it is absent it keeps `.resizeAspect` until the
   in-app resolver returns `width`/`height`, then re-lays out once.
3. Verify `/health` counters and one `?force=1` resolve per platform.
