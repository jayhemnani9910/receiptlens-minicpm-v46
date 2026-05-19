//
//  MBMtmd.h
//  ReceiptLens
//
//  Thin C bridge over upstream llama.cpp mtmd public API. Exposes a pure-C
//  surface so the Swift bridging header can consume it without enabling C++
//  interop on every translation unit.
//

#ifndef MB_MTMD_H
#define MB_MTMD_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque context.
typedef struct mb_mtmd_context mb_mtmd_context;

// Initialization parameters.
typedef struct mb_mtmd_params {
    int   n_predict;
    int   n_ctx;
    int   n_ubatch;            // physical batch size; dominates GPU compute buffer (set 0 for default)
    int   n_threads;
    float temperature;
    bool  use_gpu;
    bool  mmproj_use_gpu;
    bool  warmup;
    int   image_max_tokens;    // -1 = model default
} mb_mtmd_params;

// Loop return value. `token` is a heap-allocated UTF-8 C string owned by the
// caller; free with `mb_mtmd_string_free`. When `is_end == true`, `token` may
// be NULL.
typedef struct mb_mtmd_token {
    char * token;
    bool   is_end;
} mb_mtmd_token;

// Default params (pure-temperature sampling, top_k/p disabled).
mb_mtmd_params mb_mtmd_params_default(void);

// Construct a context. Returns NULL on failure; in that case, call
// `mb_mtmd_get_last_init_error()` for a string explaining what went wrong.
// `params` may be NULL to use defaults.
mb_mtmd_context * mb_mtmd_init(const char * model_path,
                               const char * mmproj_path,
                               const mb_mtmd_params * params);

// Last error from `mb_mtmd_init` that returned NULL. Lifetime: valid until
// the next `mb_mtmd_init` call. Always returns a non-NULL pointer (empty
// string if no error has been recorded).
const char * mb_mtmd_get_last_init_error(void);

// Release all resources owned by the context.
void mb_mtmd_free(mb_mtmd_context * ctx);

// Prefill one MiniCPM-V 4.6 user turn containing an image followed by text.
// The chat-template wrapping is applied internally (`<|im_start|>user\n
// <__media__>\n<text><|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>
// \n\n`), so the model sees the image inside the user role as it was trained
// to. Returns 0 on success, non-zero on failure (use mb_mtmd_get_last_error).
int mb_mtmd_prefill_user_image_text(mb_mtmd_context * ctx,
                                    const char * image_path,
                                    const char * text);

// Prefill a chat-formatted text turn. `role` is one of "user" / "assistant"
// / "system". Wraps in MiniCPM-V 4.6 chatml internally.
int mb_mtmd_prefill_text(mb_mtmd_context * ctx, const char * text, const char * role);

// Sample one token, decode it back into the KV cache, and return it.
// Repeated calls drive generation forward until is_end becomes true (EOG).
mb_mtmd_token mb_mtmd_loop(mb_mtmd_context * ctx);

// Free a token string previously returned via mb_mtmd_token.token.
void mb_mtmd_string_free(char * str);

// Last error message attached to the given ctx; empty string if no error.
// Lifetime is tied to ctx; copy if you need to keep it.
const char * mb_mtmd_get_last_error(mb_mtmd_context * ctx);

// Wipe the KV cache (sequence 0) and reset n_past to 0. Used between turns
// when starting a fresh conversation; does NOT tear down the model.
bool mb_mtmd_clean_kv_cache(mb_mtmd_context * ctx);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // MB_MTMD_H
