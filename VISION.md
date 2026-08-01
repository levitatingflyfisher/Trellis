# Vision — the one idea

**You train the tree; the tree never trains you.**

Trellis is the OpenHearth answer to the
attention economy: one local-first app where a family reads, listens to, and
*retains* anything — any format to any format, any language to any language —
on whatever compute they happen to own, from a $90 phone to the family desktop.

Tweets fly by. News cycles rise and die. Podcasts prompt conversations. Books
leave impressions. Serious studies shape lives. This app is built on that
gradient: **ephemera decay by default; works persist; what you keep, you keep
because your own hand promoted it.** No feed ranking. No streaks. No
engagement optimization. The app must never develop an interest in your
attention — that is a design law with tests, not a promise.

## The three loads it carries

1. **Consume** — RSVP/parafoveal/scroll/speak reading, podcasts and RSS,
   EPUB/PDF/URL/paste intake, on-device transcription (multilingual) and
   translation, read-aloud. One canonical **content spine**: your position is
   a (segment, word) — never a format. Stop listening in the car; the reader
   opens at the same sentence, possibly in another language.
2. **Distill** — any source becomes a typed course (`.ohcourse`): concepts on
   a prerequisite lattice, four kinds of recall item, discourse baked in at
   distillation time so even a zero-ML phone studies with construction and
   conversation, not bare flashcards.
3. **Retain** — the proven Trellis study engine (SM-2 with the monotonic
   floor, prerequisite DAG, mastery gating, 183 tests) verbatim, then past it:
   explain-back, Socratic follow-ups, graded free recall, a per-language word
   ledger, Anki export.

## Freedom of compute

| Tier | Hardware | What runs |
|---|---|---|
| T0 | any browser / bare APK | full reader, feeds, study engine, parcels — zero models |
| T1 | cheap phone + one 40MB download | multilingual Whisper-tiny, checkpointed, screen-off |
| T2 | good phone / any desktop | Whisper-base/small, Supertonic/Kokoro TTS, local LLM |
| T3 | the household's desktop | the stove: big models the family already owns, over LAN |

Compute travels *down* the ladder as **cuttings** (`.ohparcel`): a desktop
bakes transcript + alignment + translation + course into a file; a potato
phone imports it over any share sheet and gets the full bilingual experience
with zero local ML. The cloud is never load-bearing at any tier.

## The canonical user

A friend learning a language wants to study through her favorite podcasts *in
that language*. Subscribe → episode transcribed on her phone (or overnight on
the family desktop) → synced text with per-sentence audio alignment → an
English layer via Whisper's translate task → tapped words become ledger cards
carrying their sentence and audio span → the course lattice grows. Both donor
apps failed her: one had no intake at all, the other's Whisper was
English-only. This app is judged against her, end to end.

## Honest scorecard

| Claim | Status |
|---|---|
| Study engine with prereq DAG + monotonic SM-2 | ✅ ported, donor tests green |
| Content spine with cross-modality position law | ✅ the cursor law is pinned across read/ticker/speak/play |
| Reader (4 modes), intake, library | ✅ RSVP·print·ticker·speak; EPUB/URL/paste + Gutenberg browser. URL/Gutenberg *fetching* is native-first: browsers refuse most cross-site reads (no proxy, by design) — the web doors say so and paste/import always work — or serve the PWA from Skein on the family desktop and fetching works same-origin |
| Feeds, podcasts, background player | ◐ reverse-chron river, visible decay, iTunes search, OPML, channel artwork; the mini player rehydrates paused (not blank) after a restart and an Up Next door reaches the queue with nothing playing (Campaign 9); lock-screen/pull-down-tray transport controls are wired end-to-end (`just_audio_background`, `ADR-0015` Decision 3, Campaign 9 Phase 2e — every play tags its MediaItem with id/title/album/artwork, unit-tested) but lock-screen RENDERING itself is device-only and still awaits the user's next device test, which is the only reason this stays ◐ rather than ✅ |
| Multilingual transcription, checkpointed, resumable | ✅ whisper.cpp natives aboard the APK; native lane green on the pinned model; not yet exercised on a phone |
| Brain + distillation + discourse study | ✅ BYOK cloud tier wired end to end; local/stove tiers are honest refusals, not engines |
| Backup/migration, .apkg, storage panel, wall, dashboard+PIN | ✅ |
| Neural TTS (Supertonic/Kokoro) | ◐ ADR-0006 shipped the sentence-unit spine everywhere (the paragraph-at-a-time stall is fixed on the zero-byte system rung, every platform); ADR-0007 replaced the sherpa-onnx/Piper rung with Supertonic (MIT, no phonemizer — the APK stays MIT-clean, unlike the rung it replaced) — one voice (English, OpenRAIL-M weights on the user's own download) through the models door; the gapless synthesis-ahead pipeline IS threaded into the speak loop (real fork, settings escape, generation fencing) and proven end to end through fakes — not yet proven on a real device (the ONNX Runtime sessions actually opening, actual audio). Kokoro and a web tier stay roadmap |
| Cuttings (.ohparcel), offline MT, web ML tier, FSRS | ✗ roadmap (P6) |

## Horizons (problems, not dated features)

- **The web surface ships no local ML at v1.0.** A browser-only user reads,
  studies, follows feeds, imports parcels, and uses BYOK — and the app says
  plainly what does not run there. The transformers.js-v4 tier is the fix.
- **Word-level timestamps drift on non-English audio** (upstream reality).
  The contract is sentence-level alignment; word-level is best-effort and the
  UI must never promise karaoke it cannot keep.
- **Scanned PDFs have no OCR path yet.** The honest answer today is "no text
  layer found"; the household-desktop OCR job is the intended cure.
- **The 200-language translation tail** waits on a hand-rolled ONNX seq2seq
  loop — the single riskiest ML item, deliberately off the v1 critical path.
