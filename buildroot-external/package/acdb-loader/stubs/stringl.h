#ifndef _STRINGL_H
#define _STRINGL_H
#include <string.h>
/* Qualcomm stringl.h stubs - safe string functions */
#define strlcpy(dst, src, sz) snprintf(dst, sz, "%s", src)
#define strlcat(dst, src, sz) strncat(dst, src, (sz) - strlen(dst) - 1)
static inline size_t memscpy(void *dst, size_t dst_sz, const void *src, size_t src_sz) {
    size_t copy_sz = (src_sz < dst_sz) ? src_sz : dst_sz;
    memcpy(dst, src, copy_sz);
    return copy_sz;
}
#endif
