#include "CZipSupport.h"
#include <limits.h>
#include <zlib.h>

int32_t olm_inflate_raw(
    const uint8_t *input,
    size_t input_length,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_length
) {
    if (input == NULL || output == NULL || output_length == NULL) {
        return Z_STREAM_ERROR;
    }
    if (input_length > UINT_MAX || output_capacity > UINT_MAX) {
        return Z_BUF_ERROR;
    }

    z_stream stream = {0};
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_length;
    stream.next_out = output;
    stream.avail_out = (uInt)output_capacity;

    int result = inflateInit2(&stream, -MAX_WBITS);
    if (result != Z_OK) {
        return result;
    }

    result = inflate(&stream, Z_FINISH);
    *output_length = stream.total_out;
    inflateEnd(&stream);

    return result == Z_STREAM_END ? Z_OK : result;
}

uint32_t olm_crc32(const uint8_t *input, size_t input_length) {
    uLong checksum = crc32(0L, Z_NULL, 0);
    while (input_length > 0) {
        uInt chunk_length = input_length > UINT_MAX ? UINT_MAX : (uInt)input_length;
        checksum = crc32(checksum, input, chunk_length);
        input += chunk_length;
        input_length -= chunk_length;
    }
    return (uint32_t)checksum;
}
