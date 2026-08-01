/* The pinned whisper shim — the ONLY native surface whisper_ffi binds.
 *
 * Why a shim exists at all: whisper_full_params is a huge struct whose
 * field offsets vary by version and platform. Marshalling it in Dart FFI
 * would re-declare it by hand, where one drifted field silently corrupts
 * every call. Here a C compiler guarantees the offsets; Dart sees twelve
 * flat functions of ints and pointers.
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

WFS_EXPORT struct whisper_context *wfs_init_from_file(const char *model_path) {
  whisper_log_set(wfs_log_silence, NULL);
  struct whisper_context_params cparams = whisper_context_default_params();
  /* CPU-only by contract: phones and desktops alike; GPU offload is a
   * later, explicit decision — never a silent default. */
  cparams.use_gpu = false;
  return whisper_init_from_file_with_params(model_path, cparams);
}

WFS_EXPORT void wfs_free(struct whisper_context *ctx) { whisper_free(ctx); }

WFS_EXPORT int wfs_full(struct whisper_context *ctx, const float *samples,
                        int n_samples, const char *lang, int translate,
                        int token_timestamps, int n_threads, int no_context) {
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
  return whisper_full(ctx, params, samples, n_samples);
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
