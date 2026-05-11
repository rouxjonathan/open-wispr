#ifndef OPENWISPR_CWHISPER_SHIM_H
#define OPENWISPR_CWHISPER_SHIM_H

#include <whisper.h>
// Brings in ggml_backend_load_all so we can register Metal / BLAS / CPU
// backends from their plugin dylibs — whisper-cli does this at startup,
// but as a library consumer we have to call it ourselves.
#include <ggml-backend.h>
// For ggml_log_set so we can silence whisper's per-inference info logs.
#include <ggml.h>

#endif
