# Vision — the one idea

**You train the tree; the tree never trains you.**

Trellis is the OpenHearth **learn-everything app**, and its answer to the
attention economy: one local-first app where a family reads, listens to, and
*retains* anything — any format to any format, any language to any language —
on whatever compute they happen to own, from a $90 phone to the family desktop.

Tweets fly by. News cycles rise and die. Podcasts prompt conversations. Books
leave impressions. Serious studies shape lives. This app is built on that
gradient: **the feed is a permanent archive, newest first and never ranked;
what you keep, you keep because your own hand promoted it.** No feed ranking. No streaks. No
engagement optimization. The app must never develop an interest in your
attention — that is a design law with tests, not a promise.

**The scope test.** Trellis is not a do-everything app; it is a learn-everything
app. A feature belongs only if it serves learning: taking something in, paying
attention to it, understanding it, keeping it, or finding it again. A podcast
player, a feed reader and a lecture video pass; an endless feed or autoplay does
not. A queue the person filled is not autoplay: it ends, and going on through it
or clearing it as episodes finish is their own choice. Success is what you understood and still remember, never time spent — the
app is glad when you put it down.

## The three loads it carries

1. **Consume** — Words (RSVP)/nearby-words/scroll/lines/read-aloud reading, podcasts and RSS,
   EPUB/PDF/URL/paste intake, on-device transcription (multilingual) and
   translation, read-aloud. One canonical **content spine**: your position is
   a (segment, word) — never a format. Stop listening in the car; the reader
   opens at the same sentence, possibly in another language. And an episode
   can be heard in the language you are learning: one tap transcribes it,
   translates it, speaks the translation and keeps it as an audio file of
   its own, with the words lit as they are said.
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

The other direction is the founding request for translation
([docs/explanation/founding-request.md](docs/explanation/founding-request.md)):
a show she already loves, heard in the language she is learning. Tap play,
hear the episode in that language.

## The far picture

A household's whole reading, listening and learning life in one library
that lasts: every book, show and lecture, readable or hearable in any
language, spoken in the voice of the person who first said it, with what
each person understood and still remembers. Every engine runs on devices
the household owns. There is no account and no server. The scorecard
below says how far today is from that.

## Honest scorecard

| Claim | Status |
|---|---|
| Study engine with prereq DAG + monotonic SM-2 | ✅ ported, donor tests green |
| Content spine with cross-modality position law | ✅ the cursor law is pinned across read/ticker/speak/play |
| Reader (4 modes), intake, library | ✅ RSVP·print·ticker·speak; EPUB/URL/paste + Gutenberg browser. URL/Gutenberg *fetching* is native-first: browsers refuse most cross-site reads (no proxy, by design) — the web doors say so and paste/import always work — or serve the PWA from Skein on the family desktop and fetching works same-origin |
| Feeds, podcasts, background player | ◐ reverse-chron Latest, a permanent archive read a page at a time with a quiet "New since you last looked" line (ADR-0019, which retired decay), iTunes search, OPML, local search rebuilt in 1.5.4 (sections with true counts, word endings, prefixes, show notes and post text indexed, one engine for every search box; host-tested at 20k episodes, not yet timed on a phone), every item opening its own page with Listen and Read side by side and full show notes (links confirmed, times tappable), channel artwork; the mini player rehydrates paused (not blank) after a restart and the Queue is its own tab (Latest · Queue · Library · Courses), reachable with nothing playing; lock-screen/pull-down-tray transport controls are wired end-to-end (`just_audio_background`, `ADR-0015` Decision 3, Campaign 9 Phase 2e — every play tags its MediaItem with id/title/album/artwork, unit-tested) but lock-screen RENDERING itself is device-only and still awaits the user's next device test, which is the only reason this stays ◐ rather than ✅ |
| Multilingual transcription, checkpointed, resumable | ✅ whisper.cpp natives aboard the APK; native lane green on the pinned model; not yet exercised on a phone |
| Brain + distillation + discourse study | ✅ BYOK cloud tier wired end to end; local/stove tiers are honest refusals, not engines |
| Backup/migration, .apkg, storage panel, course map, dashboard+PIN | ✅ |
| Opens into the task; remembers the reader and how they read | ✅ every launch lands on Latest, what arrived being the usual reason to open the app (a fresh install's empty Latest points at adding a podcast and at Subscriptions); a first launch has no name to type; a cold launch reopens the last reader; mode, speed and nearby words come back on the next open (tests pin each) |
| Neural TTS (Supertonic/Kokoro) | ◐ ADR-0006 shipped the sentence-unit spine everywhere (the paragraph-at-a-time stall is fixed on the zero-byte system rung, every platform); ADR-0007 replaced the sherpa-onnx/Piper rung with Supertonic (MIT, no phonemizer — the APK stays MIT-clean, unlike the rung it replaced) — one voice (English, OpenRAIL-M weights on the user's own download) through the models door; the gapless synthesis-ahead pipeline IS threaded into the speak loop (real fork, settings escape, generation fencing) and proven end to end through fakes — not yet proven on a real device (the ONNX Runtime sessions actually opening, actual audio). Kokoro and a web tier stay roadmap |
| On-device translation | ✅ 25 pairs with English on one end, each pinned by hash; any other pair goes by way of English (ADR-0008, ADR-0014, ADR-0020) |
| Listen in the language you are learning, in one tap | ◐ one tap transcribes, translates, speaks and saves the episode as an audio file that plays like any other, labelled as a machine-made voice. The tap is the second button on an episode's row in every list, beside Play, and it is also on the episode's page: the button shows how far the making is and plays the episode when it is ready, and one episode is made at a time while the others wait their turn. It makes Spanish, French, Portuguese and English, 4 of the 12 languages Trellis translates into. Proven through tests with stand-in engines; nobody has yet heard the result on a real phone. Not on the web tier. Not built: the other 8 languages, making picked shows ahead of time, the host's own voice |
| Cuttings (.ohparcel), web ML tier, FSRS | ✗ roadmap (P6) |

## Horizons (problems, not dated features)

- **The web surface ships no local ML at v1.0.** A browser-only user reads,
  studies, follows feeds, imports parcels, and uses BYOK — and the app says
  plainly what does not run there. The transformers.js-v4 tier is the fix.
- **Word-level timestamps drift on non-English audio** (upstream reality).
  The contract is sentence-level alignment; word-level is best-effort and the
  UI must never promise karaoke it cannot keep.
- **Scanned PDFs have no OCR path yet.** The honest answer today is "no text
  layer found"; the household-desktop OCR job is the intended cure.
- **The long tail of languages.** Translation covers 25 pairs, all through
  English, a sentence at a time. Small languages have neither a translator
  nor a voice with a licence this app can carry.
- **Nobody has heard the spoken translation on a real phone.** There is no
  automatic check that speech sounds right, and no measure yet of how long
  an hour-long episode takes on an ordinary phone.
- **The host's own voice.** The engines that can copy a voice from a short
  clip need a desktop today. The household's own computer is the intended
  place for it. A machine-made voice is always labelled, in the player and
  in the file.
- **Study that a person wants to open.** The engine is sound; making a
  course still takes too much work up front.
