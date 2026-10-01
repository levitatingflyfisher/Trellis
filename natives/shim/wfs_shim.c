/* The pinned whisper shim — the ONLY native surface whisper_ffi binds.
 *
 * Why a shim exists at all: whisper_full_params is a huge struct whose
 * field offsets vary by version and platform. Marshalling it in Dart FFI
 * would re-declare it by hand, where one drifted field silently corrupts
 * every call. Here a C compiler guarantees the offsets; Dart sees flat
 * functions of ints and pointers: thirteen over a context that owns its
 * own decoder state, and fourteen wfs_state_* ones that keep the model
 * and the per-window state apart.
 *
 * ABI contract: packages/whisper_ffi/lib/src/bindings.dart is the mirror
 * of this file. Change either only with the other. Times are whisper's
 * native centiseconds; conversion happens in Dart.
 */

#include <stddef.h>
#include "whisper.h"

#if defined(_WIN32)
#define WFS_EXPORT __declspec(dllexport)
#else
#define WFS_EXPORT __attribute__((visibility("default")))
#endif

/* whisper.cpp logs to stderr by default; the app and the test harness
 * both want a silent library (pristine test output is a fleet law). */
static void wfs_log_silence(enum ggml_log_level level, const char *text,
                            void *user_data) {
  (void)level;
  (void)text;
  (void)user_data;
}

static struct whisper_context_params wfs_cparams(void) {
  whisper_log_set(wfs_log_silence, NULL);
  struct whisper_context_params cparams = whisper_context_default_params();
  /* CPU-only by contract: phones and desktops alike; GPU offload is a
   * later, explicit decision — never a silent default. */
  cparams.use_gpu = false;
  return cparams;
}

static struct whisper_full_params wfs_params(const char *lang, int translate,
                                             int token_timestamps,
                                             int n_threads, int no_context) {
  struct whisper_full_params params =
      whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  params.language = lang; /* NULL = auto-detect, per whisper contract */
  params.translate = translate != 0;
  params.token_timestamps = token_timestamps != 0;
  params.n_threads = n_threads;
  params.no_context = no_context != 0;
  params.print_progress = false;
  params.print_realtime = false;
  params.print_timestamps = false;
  params.print_special = false;
  return params;
}

WFS_EXPORT struct whisper_context *wfs_init_from_file(const char *model_path) {
  return whisper_init_from_file_with_params(model_path, wfs_cparams());
}

WFS_EXPORT void wfs_free(struct whisper_context *ctx) { whisper_free(ctx); }

WFS_EXPORT int wfs_full(struct whisper_context *ctx, const float *samples,
                        int n_samples, const char *lang, int translate,
                        int token_timestamps, int n_threads, int no_context) {
  return whisper_full(
      ctx, wfs_params(lang, translate, token_timestamps, n_threads, no_context),
      samples, n_samples);
}

WFS_EXPORT int wfs_n_segments(struct whisper_context *ctx) {
  return whisper_full_n_segments(ctx);
}

WFS_EXPORT const char *wfs_segment_text(struct whisper_context *ctx, int i) {
  return whisper_full_get_segment_text(ctx, i);
}

WFS_EXPORT int64_t wfs_segment_t0(struct whisper_context *ctx, int i) {
  return whisper_full_get_segment_t0(ctx, i);
}

WFS_EXPORT int64_t wfs_segment_t1(struct whisper_context *ctx, int i) {
  return whisper_full_get_segment_t1(ctx, i);
}

WFS_EXPORT int wfs_n_tokens(struct whisper_context *ctx, int i) {
  return whisper_full_n_tokens(ctx, i);
}

WFS_EXPORT const char *wfs_token_text(struct whisper_context *ctx, int i,
                                      int j) {
  return whisper_full_get_token_text(ctx, i, j);
}

WFS_EXPORT int64_t wfs_token_t0(struct whisper_context *ctx, int i, int j) {
  return whisper_full_get_token_data(ctx, i, j).t0;
}

WFS_EXPORT int64_t wfs_token_t1(struct whisper_context *ctx, int i, int j) {
  return whisper_full_get_token_data(ctx, i, j).t1;
}

WFS_EXPORT int wfs_token_is_special(struct whisper_context *ctx, int i,
                                    int j) {
  return whisper_full_get_token_id(ctx, i, j) >= whisper_token_eot(ctx);
}

/* The language the last wfs_full decoded in: the detected one after an
 * auto run, which lets a windowed job detect once and lock it. A static
 * string from whisper's own table (no freeing); NULL when there is none.
 * Added for 1.5.3; the Dart side looks it up optionally, so an older
 * libwhisper.so without it still loads. */
WFS_EXPORT const char *wfs_full_lang(struct whisper_context *ctx) {
  const int id = whisper_full_lang_id(ctx);
  return id < 0 ? NULL : whisper_lang_str(id);
}

/* ---- Model and state apart (1.5.3) -------------------------------------
 *
 * A context that owns its state carries decoder 0's sampling RNG from one
 * whisper_full to the next: it is seeded only when the state is created,
 * and temperature-fallback decoding draws from it. A job that kept one
 * context across windows would make each window's text depend on the
 * draws of the windows before it, so a resumed or retried job would not
 * match an uninterrupted run. These exports load the model once with no
 * state; the caller makes a fresh state per window and frees it after
 * reading the results, so every window decodes as if it were the first.
 *
 * The Dart side binds this set only when every symbol is present, and
 * otherwise falls back to the exports above. */

WFS_EXPORT struct whisper_context *wfs_state_init_model(
    const char *model_path) {
  return whisper_init_from_file_with_params_no_state(model_path,
                                                     wfs_cparams());
}

WFS_EXPORT struct whisper_state *wfs_state_new(struct whisper_context *ctx) {
  return whisper_init_state(ctx);
}

WFS_EXPORT void wfs_state_free(struct whisper_state *state) {
  whisper_free_state(state);
}

WFS_EXPORT int wfs_state_full(struct whisper_context *ctx,
                              struct whisper_state *state,
                              const float *samples, int n_samples,
                              const char *lang, int translate,
                              int token_timestamps, int n_threads,
                              int no_context) {
  return whisper_full_with_state(
      ctx, state,
      wfs_params(lang, translate, token_timestamps, n_threads, no_context),
      samples, n_samples);
}

WFS_EXPORT int wfs_state_n_segments(struct whisper_state *state) {
  return whisper_full_n_segments_from_state(state);
}

WFS_EXPORT const char *wfs_state_segment_text(struct whisper_state *state,
                                              int i) {
  return whisper_full_get_segment_text_from_state(state, i);
}

WFS_EXPORT int64_t wfs_state_segment_t0(struct whisper_state *state, int i) {
  return whisper_full_get_segment_t0_from_state(state, i);
}

WFS_EXPORT int64_t wfs_state_segment_t1(struct whisper_state *state, int i) {
  return whisper_full_get_segment_t1_from_state(state, i);
}

WFS_EXPORT int wfs_state_n_tokens(struct whisper_state *state, int i) {
  return whisper_full_n_tokens_from_state(state, i);
}

WFS_EXPORT const char *wfs_state_token_text(struct whisper_context *ctx,
                                            struct whisper_state *state,
                                            int i, int j) {
  return whisper_full_get_token_text_from_state(ctx, state, i, j);
}

WFS_EXPORT int64_t wfs_state_token_t0(struct whisper_state *state, int i,
                                      int j) {
  return whisper_full_get_token_data_from_state(state, i, j).t0;
}

WFS_EXPORT int64_t wfs_state_token_t1(struct whisper_state *state, int i,
                                      int j) {
  return whisper_full_get_token_data_from_state(state, i, j).t1;
}

WFS_EXPORT int wfs_state_token_is_special(struct whisper_context *ctx,
                                          struct whisper_state *state, int i,
                                          int j) {
  return whisper_full_get_token_id_from_state(state, i, j) >=
         whisper_token_eot(ctx);
}

/* wfs_full_lang, read from the window's state. */
WFS_EXPORT const char *wfs_state_full_lang(struct whisper_state *state) {
  const int id = whisper_full_lang_id_from_state(state);
  return id < 0 ? NULL : whisper_lang_str(id);
}
