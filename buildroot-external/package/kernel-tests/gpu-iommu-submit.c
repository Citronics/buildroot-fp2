/*
 * gpu-iommu-submit — minimal drm/msm GPU submit, used by kernel-test-iommu.
 *
 * Allocates a command buffer, maps it into the GPU's IOMMU address space
 * (prints the IOVA), submits a CP_NOP cmdstream, and waits on the fence.
 * The GPU's command processor must DMA-fetch the cmdstream from the IOVA
 * through the MSM8974 GPU SMMU; if translation is wrong the submit faults
 * the context bank and the GPU hangs.
 *
 * Exit codes:
 *   0  submit + wait ioctls succeeded
 *   2  no render node (GPU not up)
 *   3  an ioctl failed (see stderr)
 *
 * NOTE: a passing exit code is NOT by itself proof the GPU executed
 * correctly (WAIT_FENCE can return on a stale seqno). The test harness
 * MUST also confirm no context fault / hangcheck appeared in dmesg after
 * this runs. Raw ioctls, no libdrm.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

typedef uint32_t __u32; typedef uint64_t __u64; typedef int32_t __s32; typedef int64_t __s64;

#define DRM_IOCTL_BASE   'd'
#define DRM_COMMAND_BASE 0x40
#define DRM_IOWR(nr,type) _IOWR(DRM_IOCTL_BASE,(nr),type)
#define DRM_IOW(nr,type)  _IOW(DRM_IOCTL_BASE,(nr),type)

struct drm_msm_param { __u32 pipe, param; __u64 value; __u32 len, pad; };
struct drm_msm_gem_new { __u64 size; __u32 flags, handle; };
struct drm_msm_gem_info { __u32 handle, info; __u64 value; __u32 len, pad; };
struct drm_msm_gem_submit_cmd { __u32 type, submit_idx, submit_offset, size, pad, nr_relocs; __u64 relocs; };
struct drm_msm_gem_submit_bo { __u32 flags, handle; __u64 presumed; };
struct drm_msm_gem_submit { __u32 flags, fence, nr_bos, nr_cmds; __u64 bos, cmds;
	__s32 fence_fd; __u32 queueid; __u64 in_syncobjs, out_syncobjs;
	__u32 nr_in_syncobjs, nr_out_syncobjs, syncobj_stride, pad; };
struct drm_msm_timespec { __s64 tv_sec, tv_nsec; };
struct drm_msm_wait_fence { __u32 fence, flags; struct drm_msm_timespec timeout; __u32 queueid; };
struct drm_msm_submitqueue { __u32 flags, prio, id; };

#define MSM_PIPE_3D0        0x10
#define MSM_PARAM_GPU_ID    0x01
#define MSM_PARAM_CHIP_ID   0x03
#define MSM_BO_WC           0x00020000
#define MSM_INFO_GET_OFFSET 0x00
#define MSM_INFO_GET_IOVA   0x01
#define MSM_SUBMIT_CMD_BUF  0x0001
#define MSM_SUBMIT_BO_READ  0x0001

#define IOCTL_GET_PARAM       DRM_IOWR(DRM_COMMAND_BASE+0x00, struct drm_msm_param)
#define IOCTL_GEM_NEW         DRM_IOWR(DRM_COMMAND_BASE+0x02, struct drm_msm_gem_new)
#define IOCTL_GEM_INFO        DRM_IOWR(DRM_COMMAND_BASE+0x03, struct drm_msm_gem_info)
#define IOCTL_GEM_SUBMIT      DRM_IOWR(DRM_COMMAND_BASE+0x06, struct drm_msm_gem_submit)
#define IOCTL_WAIT_FENCE      DRM_IOW (DRM_COMMAND_BASE+0x07, struct drm_msm_wait_fence)
#define IOCTL_SUBMITQUEUE_NEW DRM_IOWR(DRM_COMMAND_BASE+0x0A, struct drm_msm_submitqueue)

static __u64 getparam(int fd, __u32 p)
{
	struct drm_msm_param a; memset(&a,0,sizeof a);
	a.pipe = MSM_PIPE_3D0; a.param = p;
	if (ioctl(fd, IOCTL_GET_PARAM, &a)) return 0;
	return a.value;
}

int main(void)
{
	int fd = open("/dev/dri/renderD128", O_RDWR);
	if (fd < 0) { fprintf(stderr, "open renderD128: %s\n", strerror(errno)); return 2; }

	printf("gpu_id=%llu chip_id=0x%llx\n",
	       (unsigned long long)getparam(fd, MSM_PARAM_GPU_ID),
	       (unsigned long long)getparam(fd, MSM_PARAM_CHIP_ID));

	struct drm_msm_submitqueue q; memset(&q,0,sizeof q);
	if (ioctl(fd, IOCTL_SUBMITQUEUE_NEW, &q)) { fprintf(stderr,"SUBMITQUEUE_NEW: %s\n",strerror(errno)); return 3; }

	struct drm_msm_gem_new n; memset(&n,0,sizeof n);
	n.size = 4096; n.flags = MSM_BO_WC;
	if (ioctl(fd, IOCTL_GEM_NEW, &n)) { fprintf(stderr,"GEM_NEW: %s\n",strerror(errno)); return 3; }

	struct drm_msm_gem_info gi; memset(&gi,0,sizeof gi);
	gi.handle = n.handle; gi.info = MSM_INFO_GET_IOVA;
	if (ioctl(fd, IOCTL_GEM_INFO, &gi)) { fprintf(stderr,"GEM_INFO(IOVA): %s\n",strerror(errno)); return 3; }
	printf("cmdbuf_iova=0x%llx\n", (unsigned long long)gi.value);

	struct drm_msm_gem_info go; memset(&go,0,sizeof go);
	go.handle = n.handle; go.info = MSM_INFO_GET_OFFSET;
	if (ioctl(fd, IOCTL_GEM_INFO, &go)) { fprintf(stderr,"GEM_INFO(OFFSET): %s\n",strerror(errno)); return 3; }
	uint32_t *cs = mmap(0, 4096, PROT_READ|PROT_WRITE, MAP_SHARED, fd, go.value);
	if (cs == MAP_FAILED) { fprintf(stderr,"mmap: %s\n",strerror(errno)); return 3; }
	cs[0] = 0xC0000000u | (0u << 16) | (0x10u << 8); /* type-3 CP_NOP, 1 dword */
	cs[1] = 0x00000000u;

	struct drm_msm_gem_submit_bo bo; memset(&bo,0,sizeof bo);
	bo.flags = MSM_SUBMIT_BO_READ; bo.handle = n.handle;
	struct drm_msm_gem_submit_cmd cmd; memset(&cmd,0,sizeof cmd);
	cmd.type = MSM_SUBMIT_CMD_BUF; cmd.submit_idx = 0; cmd.submit_offset = 0; cmd.size = 8;
	struct drm_msm_gem_submit s; memset(&s,0,sizeof s);
	s.flags = MSM_PIPE_3D0; s.nr_bos = 1; s.nr_cmds = 1;
	s.bos = (uintptr_t)&bo; s.cmds = (uintptr_t)&cmd; s.queueid = q.id;
	if (ioctl(fd, IOCTL_GEM_SUBMIT, &s)) { fprintf(stderr,"GEM_SUBMIT: %s\n",strerror(errno)); return 3; }
	printf("submitted fence=%u\n", s.fence);

	struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
	struct drm_msm_wait_fence w; memset(&w,0,sizeof w);
	w.fence = s.fence; w.queueid = q.id;
	w.timeout.tv_sec = now.tv_sec + 3; w.timeout.tv_nsec = now.tv_nsec;
	if (ioctl(fd, IOCTL_WAIT_FENCE, &w)) { fprintf(stderr,"WAIT_FENCE: %s\n",strerror(errno)); return 3; }

	printf("wait_fence ok\n");
	close(fd);
	return 0;
}
