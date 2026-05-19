//
//  MBMtmd.mm
//  ReceiptLens
//
//  Implementation of the MBMtmd C bridge over upstream llama.cpp mtmd.
//

#import "MBMtmd.h"

#include <llama/llama.h>
#include <llama/mtmd.h>
#include <llama/mtmd-helper.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

// One-shot helper for llama_token -> std::string using only public llama.h API.
std::string token_to_piece_impl(const llama_vocab * vocab, llama_token token) {
    char buf[256];
    int32_t n = llama_token_to_piece(vocab, token, buf, sizeof(buf), /*lstrip=*/0, /*special=*/false);
    if (n >= 0) {
        return std::string(buf, n);
    }
    std::vector<char> wide(static_cast<size_t>(-n));
    int32_t n2 = llama_token_to_piece(vocab, token, wide.data(), static_cast<int32_t>(wide.size()),
                                      /*lstrip=*/0, /*special=*/false);
    if (n2 < 0) {
        return std::string();
    }
    return std::string(wide.data(), static_cast<size_t>(n2));
}

// Add a single token to a freshly-cleared llama_batch.
void batch_add_one(llama_batch & b, llama_token tok, llama_pos pos, llama_seq_id seq) {
    b.n_tokens         = 1;
    b.token[0]         = tok;
    b.pos[0]           = pos;
    b.n_seq_id[0]      = 1;
    b.seq_id[0][0]     = seq;
    b.logits[0]        = 1;
}

struct llama_model_deleter   { void operator()(llama_model   * m) const { if (m) llama_model_free(m); } };
struct llama_context_deleter { void operator()(llama_context * c) const { if (c) llama_free(c);       } };
struct llama_sampler_deleter { void operator()(llama_sampler * s) const { if (s) llama_sampler_free(s); } };
struct mtmd_context_deleter  { void operator()(mtmd_context  * v) const { if (v) mtmd_free(v);        } };

using llama_model_ptr   = std::unique_ptr<llama_model,   llama_model_deleter>;
using llama_context_ptr = std::unique_ptr<llama_context, llama_context_deleter>;
using llama_sampler_ptr = std::unique_ptr<llama_sampler, llama_sampler_deleter>;
using mtmd_context_ptr  = std::unique_ptr<mtmd_context,  mtmd_context_deleter>;

// Backend init must happen exactly once per process lifetime. llama_backend_init
// allocates global state; calling it on every model reload would be wasteful.
// We never call llama_backend_free — iOS app teardown will reclaim it.
std::once_flag g_backend_once;
void ensure_backend_inited() {
    std::call_once(g_backend_once, []() { llama_backend_init(); });
}

// Last error from a failed mb_mtmd_init call. Lives in static storage so the
// caller can read it after the in-construction ctx has been destroyed.
std::mutex g_init_error_mutex;
std::string g_last_init_error;

void set_init_error(const std::string & err) {
    std::lock_guard<std::mutex> lock(g_init_error_mutex);
    g_last_init_error = err;
    fprintf(stderr, "[MBMtmd] %s\n", err.c_str());
}

} // namespace

struct mb_mtmd_context {
    llama_model_ptr     model;
    llama_context_ptr   lctx;
    llama_sampler_ptr   sampler;
    mtmd_context_ptr    vision;

    int32_t             n_batch = 2048;
    llama_batch         batch{};
    bool                batch_inited = false;

    const llama_vocab * vocab = nullptr;
    llama_pos           n_past = 0;
    std::string         last_error;

    ~mb_mtmd_context() {
        if (batch_inited) {
            llama_batch_free(batch);
        }
    }
};

// ---------------------------------------------------------------------------
//  Helpers
// ---------------------------------------------------------------------------

static void set_error(mb_mtmd_context * ctx, const std::string & err) {
    if (ctx) ctx->last_error = err;
    fprintf(stderr, "[MBMtmd] %s\n", err.c_str());
}

// ---------------------------------------------------------------------------
//  Public C API
// ---------------------------------------------------------------------------

mb_mtmd_params mb_mtmd_params_default(void) {
    mb_mtmd_params p = {};
    p.n_predict         = -1;
    p.n_ctx             = 4096;
    p.n_ubatch          = 0;       // 0 = pick MB_DEFAULT_N_UBATCH below
    p.n_threads         = 4;
    p.temperature       = 0.7f;
    p.use_gpu           = true;
    p.mmproj_use_gpu    = true;
    p.warmup            = true;
    p.image_max_tokens  = -1;
    return p;
}

// Safe-everywhere default n_ubatch. Spends ~487 MiB of MTL0 compute buffer on
// MiniCPM-V 4.6 Q4_K_M, fitting under the ~1.5 GB application memory limit on
// a 4 GB iPhone. Callers should override per-device.
static constexpr int MB_DEFAULT_N_UBATCH = 512;

const char * mb_mtmd_get_last_init_error(void) {
    std::lock_guard<std::mutex> lock(g_init_error_mutex);
    // Return a pointer to a static buffer that survives the lock; copy under
    // lock and stash in a static buffer the caller can read.
    static thread_local std::string snapshot;
    snapshot = g_last_init_error;
    return snapshot.c_str();
}

mb_mtmd_context * mb_mtmd_init(const char * model_path,
                               const char * mmproj_path,
                               const mb_mtmd_params * params_in) {
    {
        std::lock_guard<std::mutex> lock(g_init_error_mutex);
        g_last_init_error.clear();
    }

    if (!model_path || !*model_path || !mmproj_path || !*mmproj_path) {
        set_init_error("mb_mtmd_init: missing model_path or mmproj_path");
        return nullptr;
    }

    mb_mtmd_params params = params_in ? *params_in : mb_mtmd_params_default();

    ensure_backend_inited();

    std::unique_ptr<mb_mtmd_context> ctx(new mb_mtmd_context());

    // ---- Load text model ----
    llama_model_params mparams = llama_model_default_params();
    mparams.use_mmap     = true;
    mparams.use_mlock    = false;
    mparams.n_gpu_layers = params.use_gpu ? 999 : 0;

    ctx->model.reset(llama_model_load_from_file(model_path, mparams));
    if (!ctx->model) {
        set_init_error(std::string("Failed to load model from: ") + model_path);
        return nullptr;
    }

    // ---- Create llama_context ----
    const int requested_ubatch = params.n_ubatch > 0 ? params.n_ubatch : MB_DEFAULT_N_UBATCH;

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = static_cast<uint32_t>(params.n_ctx > 0 ? params.n_ctx : 4096);
    cparams.n_batch         = 2048;
    cparams.n_ubatch        = static_cast<uint32_t>(requested_ubatch);
    cparams.n_threads       = params.n_threads;
    cparams.n_threads_batch = params.n_threads;
    cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    cparams.no_perf         = false;

    fprintf(stderr, "[MBMtmd] llama_context: n_ctx=%u n_batch=%u n_ubatch=%u flash_attn=AUTO\n",
            cparams.n_ctx, cparams.n_batch, cparams.n_ubatch);

    ctx->lctx.reset(llama_init_from_model(ctx->model.get(), cparams));
    if (!ctx->lctx) {
        set_init_error("Failed to create llama_context");
        return nullptr;
    }

    ctx->vocab   = llama_model_get_vocab(ctx->model.get());
    ctx->n_batch = static_cast<int32_t>(llama_n_batch(ctx->lctx.get()));

    // ---- Build sampler chain (pure-temperature; MiniCPM-V default) ----
    {
        llama_sampler_chain_params scp = llama_sampler_chain_default_params();
        scp.no_perf = false;
        ctx->sampler.reset(llama_sampler_chain_init(scp));
        if (!ctx->sampler) {
            set_init_error("Failed to init sampler chain");
            return nullptr;
        }
        if (params.temperature > 0.0f) {
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_temp(params.temperature));
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
        } else {
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_greedy());
        }
    }

    // ---- Allocate generation batch ----
    ctx->batch        = llama_batch_init(ctx->n_batch, /*embd=*/0, /*n_seq_max=*/1);
    ctx->batch_inited = true;
    if (!ctx->batch.token) {
        set_init_error("Failed to llama_batch_init");
        return nullptr;
    }

    // ---- Init vision context ----
    {
        mtmd_context_params vparams = mtmd_context_params_default();
        vparams.use_gpu          = params.mmproj_use_gpu;
        vparams.print_timings    = false;
        vparams.n_threads        = params.n_threads;
        vparams.warmup           = params.warmup;
        vparams.image_max_tokens = params.image_max_tokens;

        ctx->vision.reset(mtmd_init_from_file(mmproj_path, ctx->model.get(), vparams));
        if (!ctx->vision) {
            set_init_error(std::string("Failed to load mmproj from: ") + mmproj_path);
            return nullptr;
        }
    }

    return ctx.release();
}

void mb_mtmd_free(mb_mtmd_context * ctx) {
    delete ctx;
}

void mb_mtmd_string_free(char * str) {
    if (str) free(str);
}

const char * mb_mtmd_get_last_error(mb_mtmd_context * ctx) {
    if (!ctx) return "";
    return ctx->last_error.c_str();
}

bool mb_mtmd_clean_kv_cache(mb_mtmd_context * ctx) {
    if (!ctx || !ctx->lctx) return false;
    llama_memory_seq_rm(llama_get_memory(ctx->lctx.get()), /*seq=*/0, /*p0=*/0, /*p1=*/-1);
    ctx->n_past = 0;
    return true;
}

// ---------------------------------------------------------------------------
//  Memory rollback helper
// ---------------------------------------------------------------------------

// Try to roll the KV cache back to start_n_past after a partially-applied
// prefill failure. MiniCPM-V 4.6's LLM is hybrid SSM+Attention; partial
// truncation may be unsupported, in which case the whole sequence is wiped.
static bool rollback_to_n_past(mb_mtmd_context * ctx, llama_pos start_n_past) {
    llama_memory_t mem = llama_get_memory(ctx->lctx.get());
    if (start_n_past > 0) {
        if (llama_memory_seq_rm(mem, /*seq=*/0, /*p0=*/start_n_past, /*p1=*/-1)) {
            ctx->n_past = start_n_past;
            return true;
        }
        fprintf(stderr, "[MBMtmd] partial rollback to n_past=%d unsupported by this memory module; falling back to full wipe.\n",
                static_cast<int>(start_n_past));
    }
    llama_memory_seq_rm(mem, /*seq=*/0, /*p0=*/0, /*p1=*/-1);
    ctx->n_past = 0;
    return false;
}

// ---------------------------------------------------------------------------
//  Prefill
// ---------------------------------------------------------------------------

namespace {

// Run mtmd_helper_eval_chunks over an already-tokenized chunk list, applying
// the partial-rollback policy on failure.
int eval_chunks(mb_mtmd_context * ctx,
                const char * label,
                mtmd_input_chunks * chunks,
                bool logits_last) {
    const llama_pos start_n_past = ctx->n_past;
    llama_pos new_n_past = start_n_past;
    int32_t ev = mtmd_helper_eval_chunks(ctx->vision.get(),
                                         ctx->lctx.get(),
                                         chunks,
                                         start_n_past,
                                         /*seq_id=*/0,
                                         ctx->n_batch,
                                         logits_last,
                                         &new_n_past);
    if (ev != 0) {
        const bool clean = rollback_to_n_past(ctx, start_n_past);
        const std::string suffix = clean
            ? " (KV rolled back to n_past=" + std::to_string(start_n_past) + ")"
            : " (partial rollback unsupported on SSM/hybrid; full wipe + n_past=0)";
        set_error(ctx, std::string(label) + ": mtmd_helper_eval_chunks failed, ret=" + std::to_string(ev) + suffix);
        return -1;
    }
    ctx->n_past = new_n_past;
    return 0;
}

} // namespace

int mb_mtmd_prefill_user_image_text(mb_mtmd_context * ctx,
                                    const char * image_path,
                                    const char * text_in) {
    if (!ctx || !image_path || !*image_path || !text_in) {
        if (ctx) set_error(ctx, "prefill_user_image_text: empty image_path or text");
        return -1;
    }

    mtmd_bitmap * raw_bmp = mtmd_helper_bitmap_init_from_file(ctx->vision.get(), image_path);
    if (!raw_bmp) {
        set_error(ctx, std::string("prefill_user_image_text: failed to load image: ") + image_path);
        return -1;
    }
    std::unique_ptr<mtmd_bitmap, void(*)(mtmd_bitmap*)> bmp(raw_bmp, mtmd_bitmap_free);

    // MiniCPM-V 4.6 instruct chatml: image lives INSIDE the user role wrapper.
    // The model was trained on `<|im_start|>user\n<image>\n<text><|im_end|>...`;
    // emitting the image outside the role tags is out-of-distribution.
    // The default media marker (`<__media__>`) is what mtmd_tokenize splices the
    // bitmap into.
    std::string formatted;
    formatted += "<|im_start|>user\n";
    formatted += mtmd_default_marker();
    formatted += "\n";
    formatted += text_in;
    formatted += "<|im_end|>\n";
    formatted += "<|im_start|>assistant\n<think>\n\n</think>\n\n";

    mtmd_input_text in;
    in.text          = formatted.c_str();
    in.add_special   = (ctx->n_past == 0);
    in.parse_special = true;

    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    if (!chunks) {
        set_error(ctx, "prefill_user_image_text: mtmd_input_chunks_init failed");
        return -1;
    }
    std::unique_ptr<mtmd_input_chunks, void(*)(mtmd_input_chunks*)> chunks_guard(chunks, mtmd_input_chunks_free);

    const mtmd_bitmap * bmp_arr[1] = { bmp.get() };
    int32_t res = mtmd_tokenize(ctx->vision.get(), chunks, &in, bmp_arr, 1);
    if (res != 0) {
        set_error(ctx, "prefill_user_image_text: mtmd_tokenize failed, res=" + std::to_string(res));
        return -1;
    }

    // logits_last=true so the next mb_mtmd_loop has fresh logits to sample.
    return eval_chunks(ctx, "prefill_user_image_text", chunks, /*logits_last=*/true);
}

int mb_mtmd_prefill_text(mb_mtmd_context * ctx, const char * text_in, const char * role_in) {
    if (!ctx || !text_in || !role_in || !*text_in || !*role_in) {
        if (ctx) set_error(ctx, "prefill_text: empty text or role");
        return -1;
    }

    const std::string text = text_in;
    const std::string role = role_in;

    std::string formatted;
    if (role == "user") {
        formatted += "<|im_start|>user\n" + text + "<|im_end|>\n";
        formatted += "<|im_start|>assistant\n<think>\n\n</think>\n\n";
    } else if (role == "assistant") {
        formatted = text + "<|im_end|>\n";
    } else if (role == "system") {
        formatted = "<|im_start|>system\n" + text + "<|im_end|>\n";
    } else {
        set_error(ctx, "prefill_text: unknown role: " + role);
        return -1;
    }

    mtmd_input_text in;
    in.text          = formatted.c_str();
    in.add_special   = (ctx->n_past == 0);
    in.parse_special = true;

    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    if (!chunks) {
        set_error(ctx, "prefill_text: mtmd_input_chunks_init failed");
        return -1;
    }
    std::unique_ptr<mtmd_input_chunks, void(*)(mtmd_input_chunks*)> chunks_guard(chunks, mtmd_input_chunks_free);

    int32_t res = mtmd_tokenize(ctx->vision.get(), chunks, &in, /*bitmaps=*/nullptr, /*n_bitmaps=*/0);
    if (res != 0) {
        set_error(ctx, "prefill_text: mtmd_tokenize failed, res=" + std::to_string(res));
        return -1;
    }

    return eval_chunks(ctx, "prefill_text", chunks, /*logits_last=*/true);
}

mb_mtmd_token mb_mtmd_loop(mb_mtmd_context * ctx) {
    mb_mtmd_token result = { /*token=*/nullptr, /*is_end=*/true };
    if (!ctx || !ctx->lctx || !ctx->sampler) return result;

    llama_token tok = llama_sampler_sample(ctx->sampler.get(), ctx->lctx.get(), /*idx=*/-1);
    llama_sampler_accept(ctx->sampler.get(), tok);

    const bool is_eog = llama_vocab_is_eog(ctx->vocab, tok);
    std::string piece = is_eog ? std::string() : token_to_piece_impl(ctx->vocab, tok);

    // Feed token back into KV cache to keep n_past consistent.
    batch_add_one(ctx->batch, tok, ctx->n_past, /*seq=*/0);
    ctx->n_past++;
    if (llama_decode(ctx->lctx.get(), ctx->batch) != 0) {
        set_error(ctx, "loop: llama_decode failed");
        result.is_end = true;
        return result;
    }

    if (is_eog) {
        result.is_end = true;
        return result;
    }

    result.token = static_cast<char *>(malloc(piece.size() + 1));
    if (result.token) {
        memcpy(result.token, piece.data(), piece.size());
        result.token[piece.size()] = '\0';
    }
    result.is_end = false;
    return result;
}
