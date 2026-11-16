// LectureLift's view of the libDF C API (DeepFilterNet Plus @ 2dc5273d + patches/0001-lecturelift-capi.patch).
// The library is loaded at runtime with dlopen (Denoiser/DFNBackend), so these are typedefs only.
#pragma once
#include <stddef.h>
typedef struct DFState DFState;
typedef DFState *(*hs_df_create_fn)(const char *model_path, float atten_lim_db, float min_db_thresh,
                                    float max_db_erb_thresh, float max_db_df_thresh);   // NULL on error
typedef float (*hs_df_process_frame_fn)(DFState *st, float *in, float *out);           // NaN on error
typedef size_t (*df_get_frame_length_fn)(DFState *st);
typedef void (*df_set_atten_lim_fn)(DFState *st, float lim_db);
typedef void (*df_free_fn)(DFState *st);
