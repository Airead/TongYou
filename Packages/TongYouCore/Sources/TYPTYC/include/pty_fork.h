#ifndef PTY_FORK_H
#define PTY_FORK_H

#include <sys/types.h>

/// Fork a child process and set up the slave PTY as its controlling terminal.
///
/// In the child: setsid, TIOCSCTTY, dup2(slave → stdin/stdout/stderr), execve(shell).
/// In the parent: returns the child PID (> 0), or -1 on fork failure.
///
/// @param slave_fd   Slave side of the PTY pair.
/// @param master_fd  Master side (closed in the child).
/// @param shell_path Absolute path to the shell executable.
/// @param argv       NULL-terminated argument array for execve.
/// @param envp       NULL-terminated environment array for execve.
/// @param cwd        Working directory for the child process (NULL = inherit parent).
/// @return Child PID on success, -1 on failure (errno is set).
pid_t pty_fork_exec(int slave_fd, int master_fd,
                    const char *shell_path,
                    char *const argv[],
                    char *const envp[],
                    const char *cwd);

/// Query the current working directory of a process.
///
/// @param pid     Process ID to query.
/// @param buf     Buffer to receive the path (must be at least MAXPATHLEN bytes).
/// @param bufsize Size of the buffer.
/// @return 0 on success, -1 on failure.
int pty_get_cwd(pid_t pid, char *buf, int bufsize);

/// Query the name of the foreground process running in a PTY.
///
/// Uses tcgetpgrp() to find the foreground process group leader,
/// then queries the OS for its executable name.
///
/// @param master_fd  Master side of the PTY pair.
/// @param buf        Buffer to receive the process name.
/// @param bufsize    Size of the buffer (MAXCOMLEN+1 = 17 is sufficient).
/// @return 0 on success, -1 on failure.
int pty_get_foreground_process_name(int master_fd, char *buf, int bufsize);

#endif /* PTY_FORK_H */
