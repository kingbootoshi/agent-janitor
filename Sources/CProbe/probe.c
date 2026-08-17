#include "include/probe.h"
#include <string.h>

int aj_list_pids(int *buf, int cap_bytes) {
    return proc_listallpids(buf, cap_bytes);
}

int aj_bsdinfo(int pid, struct proc_bsdinfo *out) {
    memset(out, 0, sizeof(*out));
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, out, sizeof(*out));
}

int aj_rusage(int pid, struct rusage_info_v4 *out) {
    memset(out, 0, sizeof(*out));
    return proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)out);
}

int aj_path(int pid, char *buf, uint32_t cap) {
    return proc_pidpath(pid, buf, cap);
}

int aj_cwd(int pid, struct proc_vnodepathinfo *out) {
    memset(out, 0, sizeof(*out));
    return proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, out, sizeof(*out));
}

int aj_fds(int pid, struct proc_fdinfo *buf, int cap_bytes) {
    return proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf, cap_bytes);
}

int aj_socket(int pid, int fd, struct socket_fdinfo *out) {
    memset(out, 0, sizeof(*out));
    return proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, out, sizeof(*out));
}

int aj_pipe(int pid, int fd, struct pipe_fdinfo *out) {
    memset(out, 0, sizeof(*out));
    return proc_pidfdinfo(pid, fd, PROC_PIDFDPIPEINFO, out, sizeof(*out));
}

int aj_args(int pid, char *buf, size_t *len) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    return sysctl(mib, 3, buf, len, NULL, 0);
}
