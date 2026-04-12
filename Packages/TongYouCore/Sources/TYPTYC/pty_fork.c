#include <pty_fork.h>

#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/param.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>

#if defined(__APPLE__)
#include <libproc.h>
#elif defined(__linux__)
#include <stdio.h>
#include <limits.h>
#endif

pid_t pty_fork_exec(int slave_fd, int master_fd,
                    const char *shell_path,
                    char *const argv[],
                    char *const envp[],
                    const char *cwd)
{
    pid_t pid = fork();
    if (pid < 0) {
        return -1;  /* fork failed */
    }

    if (pid == 0) {
        /* --- Child process (only async-signal-safe calls) --- */

        /* Create a new session (detach from parent's controlling terminal) */
        setsid();

        /* Make the slave PTY the controlling terminal */
        ioctl(slave_fd, TIOCSCTTY, 0);

        /* Redirect stdin/stdout/stderr to the slave PTY */
        dup2(slave_fd, STDIN_FILENO);
        dup2(slave_fd, STDOUT_FILENO);
        dup2(slave_fd, STDERR_FILENO);

        /* Close the original fds (no longer needed) */
        if (slave_fd > STDERR_FILENO) {
            close(slave_fd);
        }
        close(master_fd);

        /* Change working directory if specified */
        if (cwd) {
            chdir(cwd);
        }

        /* Execute the shell */
        execve(shell_path, argv, envp);

        /* If execve returns, it failed */
        _exit(1);
    }

    /* --- Parent process --- */
    return pid;
}

int pty_get_cwd(pid_t pid, char *buf, int bufsize)
{
#if defined(__APPLE__)
    struct proc_vnodepathinfo vpi;
    int ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (ret != (int)sizeof(vpi)) {
        return -1;
    }
    strlcpy(buf, vpi.pvi_cdir.vip_path, bufsize);
    return 0;
#elif defined(__linux__)
    char proc_path[64];
    snprintf(proc_path, sizeof(proc_path), "/proc/%d/cwd", (int)pid);
    ssize_t len = readlink(proc_path, buf, bufsize - 1);
    if (len < 0) {
        return -1;
    }
    buf[len] = '\0';
    return 0;
#else
    (void)pid; (void)buf; (void)bufsize;
    return -1;
#endif
}

int pty_get_foreground_process_name(int master_fd, char *buf, int bufsize)
{
    pid_t fg_pid = tcgetpgrp(master_fd);
    if (fg_pid < 0) {
        return -1;
    }

#if defined(__APPLE__)
    struct proc_bsdinfo info;
    int ret = proc_pidinfo(fg_pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (ret != (int)sizeof(info)) {
        return -1;
    }
    strlcpy(buf, info.pbi_comm, bufsize);
    return 0;
#elif defined(__linux__)
    char proc_path[64];
    snprintf(proc_path, sizeof(proc_path), "/proc/%d/comm", (int)fg_pid);
    FILE *f = fopen(proc_path, "r");
    if (!f) {
        return -1;
    }
    if (fgets(buf, bufsize, f) == NULL) {
        fclose(f);
        return -1;
    }
    fclose(f);
    /* Remove trailing newline */
    size_t len = strlen(buf);
    if (len > 0 && buf[len - 1] == '\n') {
        buf[len - 1] = '\0';
    }
    return 0;
#else
    (void)master_fd; (void)buf; (void)bufsize;
    return -1;
#endif
}
