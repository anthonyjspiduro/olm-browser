#ifndef C_ZIP_SUPPORT_H
#define C_ZIP_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

/// Inflates a raw DEFLATE stream, as stored in a ZIP entry.
/// Returns 0 on success and a zlib error code otherwise.
int32_t olm_inflate_raw(
    const uint8_t *input,
    size_t input_length,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_length
);

#endif
