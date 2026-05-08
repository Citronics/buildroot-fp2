#ifndef _LINUX_MSM_ION_H
#define _LINUX_MSM_ION_H
#include <linux/types.h>
#include <linux/ioctl.h>

#define ION_IOC_MAGIC 'I'
#define ION_IOC_ALLOC _IOWR(ION_IOC_MAGIC, 0, struct ion_allocation_data)
#define ION_IOC_FREE _IOWR(ION_IOC_MAGIC, 1, struct ion_handle_data)
#define ION_IOC_SHARE _IOWR(ION_IOC_MAGIC, 4, struct ion_fd_data)

#define ION_AUDIO_HEAP_ID 28
#define ION_HEAP(x) (1 << (x))
#define ION_FLAG_CACHED 1

struct ion_allocation_data {
    __u64 len;
    __u32 align;
    __u32 heap_id_mask;
    __u32 flags;
    __u32 handle;
};

struct ion_handle_data {
    __s32 handle;
};

struct ion_fd_data {
    __s32 handle;
    __s32 fd;
};

#endif
