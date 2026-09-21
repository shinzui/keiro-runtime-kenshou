#include <libproc.h>
#include <stdint.h>
#include <unistd.h>

int kenshou_proc_taskinfo(uint64_t *resident_size, int *thread_count) {
  struct proc_taskinfo info;
  int bytes = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, sizeof(info));
  if (bytes != sizeof(info)) return 0;
  *resident_size = info.pti_resident_size;
  *thread_count = info.pti_threadnum;
  return 1;
}
