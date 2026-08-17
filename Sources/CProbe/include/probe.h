#ifndef AJ_PROBE_H
#define AJ_PROBE_H

#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <stdint.h>

int aj_list_pids(int *buf, int cap_bytes);
int aj_bsdinfo(int pid, struct proc_bsdinfo *out);
int aj_rusage(int pid, struct rusage_info_v4 *out);
int aj_path(int pid, char *buf, uint32_t cap);
int aj_cwd(int pid, struct proc_vnodepathinfo *out);
int aj_fds(int pid, struct proc_fdinfo *buf, int cap_bytes);
int aj_socket(int pid, int fd, struct socket_fdinfo *out);
int aj_pipe(int pid, int fd, struct pipe_fdinfo *out);
int aj_args(int pid, char *buf, size_t *len);

#endif
