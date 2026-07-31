/* Self-restriction bindings for the run_r worker process. These run once at
 * worker startup; enforcement thereafter is the kernel's, not this code's.
 * Landlock has no libc wrapper, seccomp requires prctl() with a BPF program,
 * and macOS Seatbelt is only reachable through libSystem's sandbox_init(),
 * so none of them is reachable from R without this layer. */

#define _GNU_SOURCE

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#ifdef __linux__

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sched.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
#include <linux/audit.h>
#include <linux/capability.h>
#include <linux/filter.h>
#include <linux/seccomp.h>

/* The seccomp filter matches syscall numbers, which are architecture-specific,
 * so it must first confirm the calling arch is the native one: a foreign arch
 * (e.g. the i386 compat ABI on an x86_64 kernel) numbers its syscalls
 * differently, so socket() could slip through as a number we don't screen. An
 * unrecognized build arch fails closed rather than installing a filter that
 * screens the wrong table. */
#if defined(__x86_64__)
#define SANDBOX_AUDIT_ARCH AUDIT_ARCH_X86_64
#define SANDBOX_X32_SYSCALL_BIT 0x40000000
#elif defined(__aarch64__)
#define SANDBOX_AUDIT_ARCH AUDIT_ARCH_AARCH64
#elif defined(__i386__)
#define SANDBOX_AUDIT_ARCH AUDIT_ARCH_I386
#elif defined(__arm__)
#define SANDBOX_AUDIT_ARCH AUDIT_ARCH_ARM
#else
#error "run_r sandbox: unsupported architecture for the seccomp filter"
#endif

#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#endif
#ifndef __NR_landlock_add_rule
#define __NR_landlock_add_rule 445
#endif
#ifndef __NR_landlock_restrict_self
#define __NR_landlock_restrict_self 446
#endif

/* Syscall numbers past 424 are shared across supported architectures. */
#ifndef __NR_open_tree
#define __NR_open_tree 428
#endif
#ifndef __NR_move_mount
#define __NR_move_mount 429
#endif
#ifndef __NR_fsopen
#define __NR_fsopen 430
#endif
#ifndef __NR_fsconfig
#define __NR_fsconfig 431
#endif
#ifndef __NR_fsmount
#define __NR_fsmount 432
#endif
#ifndef __NR_fspick
#define __NR_fspick 433
#endif
#ifndef __NR_clone3
#define __NR_clone3 435
#endif
#ifndef __NR_mount_setattr
#define __NR_mount_setattr 442
#endif

#ifndef CLONE_NEWCGROUP
#define CLONE_NEWCGROUP 0x02000000
#endif

#define LL_CREATE_RULESET_VERSION (1U << 0)
#define LL_RULE_PATH_BENEATH 1

#define FS_EXECUTE (1ULL << 0)
#define FS_READ_FILE (1ULL << 2)
#define FS_READ_DIR (1ULL << 3)
#define FS_V1_ALL ((1ULL << 13) - 1)
#define FS_REFER (1ULL << 13)
#define FS_TRUNCATE (1ULL << 14)
#define FS_IOCTL_DEV (1ULL << 15)
#define FS_READ_ONLY (FS_EXECUTE | FS_READ_FILE | FS_READ_DIR)

/* Landlock leaves undeclared rights unrestricted. */
static uint64_t landlock_handled(long abi) {
  uint64_t handled = FS_V1_ALL;
  if (abi >= 2) {
    handled |= FS_REFER;
  }
  if (abi >= 3) {
    handled |= FS_TRUNCATE;
  }
  if (abi >= 5) {
    handled |= FS_IOCTL_DEV;
  }
  return handled;
}

struct ll_ruleset_attr {
  uint64_t handled_access_fs;
};
struct ll_path_beneath_attr {
  uint64_t allowed_access;
  int32_t parent_fd;
} __attribute__((packed));

static void add_roots(int ruleset_fd, SEXP roots, uint64_t access,
                      const char *what) {
  for (int i = 0; i < Rf_length(roots); i++) {
    const char *path = CHAR(STRING_ELT(roots, i));
    int parent = open(path, O_PATH | O_CLOEXEC);
    if (parent < 0) {
      close(ruleset_fd);
      Rf_error("cannot open %s root '%s': %s", what, path, strerror(errno));
    }
    struct ll_path_beneath_attr pb = {
      .allowed_access = access,
      .parent_fd = parent
    };
    long r = syscall(__NR_landlock_add_rule, ruleset_fd, LL_RULE_PATH_BENEATH,
                     &pb, 0);
    close(parent);
    if (r != 0) {
      close(ruleset_fd);
      Rf_error("landlock_add_rule failed for '%s': %s", path, strerror(errno));
    }
  }
}

/* Return availability errors so the caller can select another sandbox. */
static int landlock_engage(SEXP read_roots, SEXP rw_roots) {
  long abi = syscall(__NR_landlock_create_ruleset, NULL, 0,
                     LL_CREATE_RULESET_VERSION);
  if (abi < 0) {
    return errno;
  }
  uint64_t handled = landlock_handled(abi);
  struct ll_ruleset_attr attr = { .handled_access_fs = handled };
  int fd = (int) syscall(__NR_landlock_create_ruleset, &attr, sizeof(attr), 0);
  if (fd < 0) {
    return errno;
  }
  add_roots(fd, read_roots, FS_READ_ONLY, "read");
  add_roots(fd, rw_roots, handled, "read-write");
  if (syscall(__NR_landlock_restrict_self, fd, 0)) {
    close(fd);
    Rf_error("landlock_restrict_self failed: %s", strerror(errno));
  }
  close(fd);
  return 0;
}

/* The namespace sandbox exposes allowed roots through a new tmpfs root. */
#define USERNS_ROOT "/tmp"
#define OLD_ROOT "/.commons-oldroot"

static int count_threads(void) {
  DIR *d = opendir("/proc/self/task");
  if (d == NULL) {
    return -1;
  }
  int n = 0;
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    if (e->d_name[0] != '.') {
      n++;
    }
  }
  closedir(d);
  return n;
}

static int write_proc(const char *path, const char *content) {
  int fd = open(path, O_WRONLY | O_CLOEXEC);
  if (fd < 0) {
    return -1;
  }
  ssize_t n = write(fd, content, strlen(content));
  int err = errno;
  close(fd);
  if (n != (ssize_t) strlen(content)) {
    errno = err;
    return -1;
  }
  return 0;
}

/* Read ids before unshare(), which temporarily reports overflow ids. */
static int userns_map_ids(void) {
  uid_t uid = getuid();
  gid_t gid = getgid();
  char map[64];

  if (unshare(CLONE_NEWUSER | CLONE_NEWNS) != 0) {
    return -1;
  }
  /* Unprivileged processes must deny setgroups before mapping a gid. */
  if (write_proc("/proc/self/setgroups", "deny") != 0) {
    return -1;
  }
  snprintf(map, sizeof(map), "%u %u 1", (unsigned) uid, (unsigned) uid);
  if (write_proc("/proc/self/uid_map", map) != 0) {
    return -1;
  }
  snprintf(map, sizeof(map), "%u %u 1", (unsigned) gid, (unsigned) gid);
  if (write_proc("/proc/self/gid_map", map) != 0) {
    return -1;
  }
  return 0;
}

static void mkdir_p(char *path) {
  for (char *p = path + 1; *p != '\0'; p++) {
    if (*p == '/') {
      *p = '\0';
      if (mkdir(path, 0755) != 0 && errno != EEXIST) {
        int err = errno;
        *p = '/';
        Rf_error("cannot create '%s': %s", path, strerror(err));
      }
      *p = '/';
    }
  }
  if (mkdir(path, 0755) != 0 && errno != EEXIST) {
    Rf_error("cannot create '%s': %s", path, strerror(errno));
  }
}

static int path_in_roots(const char *path, SEXP roots) {
  for (int i = 0; i < Rf_length(roots); i++) {
    const char *root = CHAR(STRING_ELT(roots, i));
    size_t len = strlen(root);
    while (len > 1 && root[len - 1] == '/') {
      len--;
    }
    if (strncmp(path, root, len) == 0 &&
        (len == 1 || path[len] == '\0' || path[len] == '/')) {
      return 1;
    }
  }
  return 0;
}

static int fd_is_preserved(int fd, SEXP preserve_fds) {
  for (int i = 0; i < Rf_length(preserve_fds); i++) {
    if (fd == INTEGER(preserve_fds)[i]) {
      return 1;
    }
  }
  return 0;
}

static void userns_close_external_fds(SEXP read_roots, SEXP rw_roots,
                                      SEXP preserve_fds) {
  DIR *d = opendir("/proc/self/fd");
  if (d == NULL) {
    Rf_error("cannot inspect inherited file descriptors: %s", strerror(errno));
  }
  int scan_fd = dirfd(d);
  int n_fds = 0;
  int capacity = 32;
  int *fds = (int *) R_alloc(capacity, sizeof(int));
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    char *end;
    long value = strtol(e->d_name, &end, 10);
    if (*e->d_name == '\0' || *end != '\0' || value < 0 || value > INT_MAX) {
      continue;
    }
    int fd = (int) value;
    if (fd <= 2 || fd == scan_fd || fd_is_preserved(fd, preserve_fds)) {
      continue;
    }
    if (n_fds == capacity) {
      int *bigger = (int *) R_alloc(capacity * 2, sizeof(int));
      memcpy(bigger, fds, capacity * sizeof(int));
      fds = bigger;
      capacity *= 2;
    }
    fds[n_fds++] = fd;
  }
  closedir(d);

  for (int i = 0; i < n_fds; i++) {
    int fd = fds[i];
    struct stat st;
    if (fstat(fd, &st) != 0) {
      continue;
    }
    if (S_ISSOCK(st.st_mode)) {
      close(fd);
      continue;
    }
    if (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode) &&
        !S_ISCHR(st.st_mode) && !S_ISBLK(st.st_mode)) {
      continue;
    }

    char proc_path[64];
    char target[PATH_MAX];
    snprintf(proc_path, sizeof(proc_path), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(proc_path, target, sizeof(target) - 1);
    if (n < 0) {
      close(fd);
      continue;
    }
    target[n] = '\0';
    int flags = fcntl(fd, F_GETFL);
    int readable_root = flags >= 0 && (flags & O_ACCMODE) == O_RDONLY &&
                        path_in_roots(target, read_roots);
    if (!readable_root && !path_in_roots(target, rw_roots)) {
      close(fd);
    }
  }
}

static void userns_drop_capabilities(void) {
  /* Prevent capabilities returning across exec, then clear current ones. */
  for (int cap = 0; ; cap++) {
    if (prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) == 0) {
      continue;
    }
    if (errno == EINVAL) {
      break;
    }
    Rf_error("cannot drop capability %d from the bounding set: %s", cap,
             strerror(errno));
  }

  struct __user_cap_header_struct header = {
    .version = _LINUX_CAPABILITY_VERSION_3,
    .pid = 0
  };
  struct __user_cap_data_struct data[2] = {{0}};
  if (syscall(SYS_capset, &header, data) != 0) {
    Rf_error("cannot clear sandbox capabilities: %s", strerror(errno));
  }
}

/* Locked mounts require their existing flags to be preserved on remount. */
static void userns_readonly(const char *path) {
  unsigned long flags = MS_REMOUNT | MS_BIND | MS_RDONLY;
  struct statvfs sv;
  if (statvfs(path, &sv) == 0) {
    if (sv.f_flag & ST_NOSUID) flags |= MS_NOSUID;
    if (sv.f_flag & ST_NODEV) flags |= MS_NODEV;
    if (sv.f_flag & ST_NOEXEC) flags |= MS_NOEXEC;
    if (sv.f_flag & ST_NOATIME) flags |= MS_NOATIME;
    if (sv.f_flag & ST_NODIRATIME) flags |= MS_NODIRATIME;
    if (sv.f_flag & ST_RELATIME) flags |= MS_RELATIME;
  }
  if (mount(NULL, path, NULL, flags, NULL) != 0) {
    Rf_error("cannot make '%s' read-only in the sandbox: %s", path,
             strerror(errno));
  }
}

/* Locked child mounts require recursive binds and read-only remounts. */
static void userns_bind(const char *root, int rdonly, const char **submounts,
                        int n_submounts) {
  char src[PATH_MAX];
  char dst[PATH_MAX];
  if (snprintf(src, sizeof(src), OLD_ROOT "%s", root) >= (int) sizeof(src) ||
      snprintf(dst, sizeof(dst), "%s", root) >= (int) sizeof(dst)) {
    Rf_error("sandbox root path too long: '%s'", root);
  }
  mkdir_p(dst);
  if (mount(src, dst, NULL, MS_BIND | MS_REC, NULL) != 0) {
    Rf_error("cannot bind '%s' into the sandbox: %s", root, strerror(errno));
  }
  if (!rdonly) {
    return;
  }
  userns_readonly(dst);
  size_t len = strlen(root);
  int at_root = strcmp(root, "/") == 0;
  for (int i = 0; i < n_submounts; i++) {
    const char *sub = submounts[i];
    if (at_root || (strncmp(sub, root, len) == 0 && sub[len] == '/')) {
      userns_readonly(sub);
    }
  }
}

static void mountinfo_unescape(char *path) {
  char *src = path;
  char *dst = path;
  while (*src != '\0') {
    if (src[0] == '\\' && src[1] >= '0' && src[1] <= '7' &&
        src[2] >= '0' && src[2] <= '7' &&
        src[3] >= '0' && src[3] <= '7') {
      *dst++ = (char) ((src[1] - '0') * 64 + (src[2] - '0') * 8 +
                      (src[3] - '0'));
      src += 4;
    } else {
      *dst++ = *src++;
    }
  }
  *dst = '\0';
}

static const char **userns_submounts(int *n) {
  *n = 0;
  FILE *f = fopen("/proc/self/mountinfo", "r");
  if (f == NULL) {
    Rf_error("cannot inspect sandbox mounts: %s", strerror(errno));
  }
  int cap = 64;
  const char **out = (const char **) R_alloc(cap, sizeof(char *));
  char *line = NULL;
  size_t line_size = 0;
  while (getline(&line, &line_size, f) >= 0) {
    char *p = line;
    for (int field = 0; field < 4 && p != NULL; field++) {
      p = strchr(p + 1, ' ');
    }
    if (p == NULL) {
      continue;
    }
    char *start = p + 1;
    char *end = strchr(start, ' ');
    if (end == NULL) {
      continue;
    }
    *end = '\0';
    mountinfo_unescape(start);
    if (*n == cap) {
      const char **bigger = (const char **) R_alloc(cap * 2, sizeof(char *));
      memcpy(bigger, out, cap * sizeof(char *));
      out = bigger;
      cap *= 2;
    }
    char *copy = R_alloc(strlen(start) + 1, 1);
    strcpy(copy, start);
    out[(*n)++] = copy;
  }
  int read_error = ferror(f);
  int read_errno = errno;
  free(line);
  fclose(f);
  if (read_error) {
    Rf_error("cannot read sandbox mounts: %s", strerror(read_errno));
  }
  return out;
}

/* Return availability errors so the caller can report unsupported hosts. */
static int userns_engage(SEXP read_roots, SEXP rw_roots, SEXP preserve_fds) {
  int threads = count_threads();
  if (threads != 1) {
    Rf_error("cannot engage the user-namespace sandbox from a multithreaded "
             "R process (%d threads); start the worker with "
             "OPENBLAS_NUM_THREADS=1 and OMP_NUM_THREADS=1",
             threads);
  }

  char cwd[PATH_MAX];
  if (getcwd(cwd, sizeof(cwd)) == NULL) {
    Rf_error("getcwd failed: %s", strerror(errno));
  }
  if (userns_map_ids() != 0) {
    return errno;
  }

  /* Freeze mount propagation before recording nested mounts. */
  if (mount("none", "/", NULL, MS_PRIVATE | MS_REC, NULL) != 0) {
    Rf_error("cannot make / a private mount: %s", strerror(errno));
  }
  int n_submounts = 0;
  const char **submounts = userns_submounts(&n_submounts);
  userns_close_external_fds(read_roots, rw_roots, preserve_fds);

  if (mount("tmpfs", USERNS_ROOT, "tmpfs", 0, "size=16m,mode=0755") != 0) {
    Rf_error("cannot mount the sandbox root tmpfs: %s", strerror(errno));
  }

  /* Pivot first so bind sources remain reachable through OLD_ROOT. */
  if (mkdir(USERNS_ROOT OLD_ROOT, 0755) != 0) {
    Rf_error("cannot create the pivot directory: %s", strerror(errno));
  }
  if (syscall(SYS_pivot_root, USERNS_ROOT, USERNS_ROOT OLD_ROOT) != 0) {
    Rf_error("pivot_root failed: %s", strerror(errno));
  }
  if (chdir("/") != 0) {
    Rf_error("cannot chdir to the sandbox root: %s", strerror(errno));
  }

  int n_read = Rf_length(read_roots);
  int n_rw = Rf_length(rw_roots);
  for (int i = 0; i < n_read + n_rw; i++) {
    SEXP roots = i < n_read ? read_roots : rw_roots;
    userns_bind(
      CHAR(STRING_ELT(roots, i < n_read ? i : i - n_read)),
      i < n_read,
      submounts,
      n_submounts
    );
  }

  if (umount2(OLD_ROOT, MNT_DETACH) != 0) {
    Rf_error("cannot detach the host root: %s", strerror(errno));
  }
  rmdir(OLD_ROOT);
  if (mount(NULL, "/", NULL, MS_REMOUNT | MS_BIND | MS_RDONLY, NULL) != 0) {
    Rf_error("cannot make the sandbox root read-only: %s", strerror(errno));
  }
  /* A missing original cwd leaves the worker safely at "/". */
  if (chdir(cwd) != 0) {
    errno = 0;
  }
  userns_drop_capabilities();
  return 0;
}

static void seccomp_engage(void) {
#define SANDBOX_DENY(err) \
  BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ((err) & SECCOMP_RET_DATA))
#define SANDBOX_SCREEN(nr) \
  BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (nr), 0, 1), SANDBOX_DENY(EPERM)

  struct sock_filter filt[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (uint32_t) offsetof(struct seccomp_data, arch)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SANDBOX_AUDIT_ARCH, 1, 0),
    SANDBOX_DENY(EPERM),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (uint32_t) offsetof(struct seccomp_data, nr)),
#ifdef SANDBOX_X32_SYSCALL_BIT
    /* x32 syscalls share the x86_64 arch tag but set a high bit and index a
     * separate table, so screen them out before the number comparisons. */
    BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, SANDBOX_X32_SYSCALL_BIT, 0, 1),
    SANDBOX_DENY(EPERM),
#endif
    SANDBOX_SCREEN(__NR_ptrace),
    SANDBOX_SCREEN(__NR_process_vm_readv),
    SANDBOX_SCREEN(__NR_process_vm_writev),
    SANDBOX_SCREEN(__NR_mount),
    SANDBOX_SCREEN(__NR_umount2),
#ifdef __NR_umount
    SANDBOX_SCREEN(__NR_umount),
#endif
    SANDBOX_SCREEN(__NR_pivot_root),
    SANDBOX_SCREEN(__NR_chroot),
    SANDBOX_SCREEN(__NR_unshare),
    SANDBOX_SCREEN(__NR_setns),
    SANDBOX_SCREEN(__NR_open_tree),
    SANDBOX_SCREEN(__NR_move_mount),
    SANDBOX_SCREEN(__NR_fsopen),
    SANDBOX_SCREEN(__NR_fsconfig),
    SANDBOX_SCREEN(__NR_fsmount),
    SANDBOX_SCREEN(__NR_fspick),
    SANDBOX_SCREEN(__NR_mount_setattr),
    /* Force glibc to use clone(), whose flags seccomp can inspect. */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone3, 0, 1),
    SANDBOX_DENY(ENOSYS),
    /* Permit ordinary clones while rejecting namespace flags. */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone, 0, 3),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (uint32_t) offsetof(struct seccomp_data, args[0])),
    BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K,
             CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWNET | CLONE_NEWPID |
             CLONE_NEWIPC | CLONE_NEWUTS | CLONE_NEWCGROUP, 0, 1),
    SANDBOX_DENY(EPERM),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  struct sock_fprog prog = {
    .len = sizeof(filt) / sizeof(filt[0]),
    .filter = filt
  };
  if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog)) {
    Rf_error("seccomp filter install failed: %s", strerror(errno));
  }

#undef SANDBOX_SCREEN
#undef SANDBOX_DENY
}

static void network_engage(void) {
  struct sock_filter filt[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (uint32_t) offsetof(struct seccomp_data, arch)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SANDBOX_AUDIT_ARCH, 1, 0),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (uint32_t) offsetof(struct seccomp_data, nr)),
#ifdef SANDBOX_X32_SYSCALL_BIT
    BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, SANDBOX_X32_SYSCALL_BIT, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
#endif
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socket, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  struct sock_fprog prog = {
    .len = sizeof(filt) / sizeof(filt[0]),
    .filter = filt
  };
  if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog)) {
    Rf_error("network filter install failed: %s", strerror(errno));
  }
}

SEXP c_sandbox_capabilities(void) {
  long landlock_abi = syscall(__NR_landlock_create_ruleset, NULL, 0,
                              LL_CREATE_RULESET_VERSION);
  int seccomp_ok = prctl(PR_GET_SECCOMP, 0, 0, 0, 0) >= 0;
  /* Probe namespace creation and id mapping in a throwaway child. */
  int userns_ok = 0;
  pid_t pid = fork();
  if (pid == 0) {
    _exit(userns_map_ids() == 0 ? 0 : 1);
  } else if (pid > 0) {
    int status;
    if (waitpid(pid, &status, 0) == pid) {
      userns_ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    }
  }
  SEXP out = PROTECT(Rf_allocVector(INTSXP, 4));
  INTEGER(out)[0] = (int) landlock_abi;
  INTEGER(out)[1] = seccomp_ok;
  INTEGER(out)[2] = 0;
  INTEGER(out)[3] = userns_ok;
  UNPROTECT(1);
  return out;
}

SEXP c_sandbox_engage(SEXP read_roots, SEXP rw_roots, SEXP memory_limit,
                      SEXP mode_sexp, SEXP preserve_fds, SEXP network_sexp) {
  const char *mode = CHAR(STRING_ELT(mode_sexp, 0));
  if (strcmp(mode, "auto") != 0 && strcmp(mode, "landlock") != 0 &&
      strcmp(mode, "userns") != 0) {
    Rf_error("unknown sandbox mode '%s'", mode);
  }
  const char *network = CHAR(STRING_ELT(network_sexp, 0));
  if (strcmp(network, "none") != 0 && strcmp(network, "full") != 0) {
    Rf_error("unknown network access level '%s'", network);
  }

  if (memory_limit != R_NilValue) {
    rlim_t bytes = (rlim_t) REAL(memory_limit)[0];
    struct rlimit lim = { .rlim_cur = bytes, .rlim_max = bytes };
    if (setrlimit(RLIMIT_AS, &lim) != 0) {
      Rf_error("setrlimit(RLIMIT_AS) failed: %s", strerror(errno));
    }
  }

  /* Landlock and seccomp require no_new_privs for unprivileged processes. */
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) {
    Rf_error("prctl(PR_SET_NO_NEW_PRIVS) failed: %s", strerror(errno));
  }

  const char *tier = NULL;
  if (strcmp(mode, "landlock") == 0 || strcmp(mode, "auto") == 0) {
    int err = landlock_engage(read_roots, rw_roots);
    if (err == 0) {
      tier = "landlock";
    } else if (strcmp(mode, "landlock") == 0 ||
               (err != ENOSYS && err != EOPNOTSUPP && err != EPERM)) {
      Rf_error("landlock_create_ruleset failed: %s", strerror(err));
    }
  }
  if (tier == NULL &&
      (strcmp(mode, "userns") == 0 || strcmp(mode, "auto") == 0)) {
    int err = userns_engage(read_roots, rw_roots, preserve_fds);
    if (err == 0) {
      tier = "userns";
    } else if (strcmp(mode, "userns") == 0) {
      Rf_error("unshare(CLONE_NEWUSER|CLONE_NEWNS) failed: %s",
               strerror(err));
    } else {
      Rf_error(
        "cannot sandbox the run_r session: this system offers neither "
        "Landlock nor unprivileged user namespaces "
        "(unshare failed: %s)",
        strerror(err));
    }
  }

  seccomp_engage();
  if (strcmp(network, "none") == 0) {
    network_engage();
  }

  return Rf_mkString(tier);
}

#elif defined(__APPLE__)

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>

/* Seatbelt's C entry points live in libSystem. <sandbox.h> declares them
 * deprecated (since 10.8) with no replacement for unentitled processes;
 * declaring them directly keeps the build warning-free. */
extern int sandbox_init(const char *profile, uint64_t flags, char **errorbuf);
extern void sandbox_free_error(char *errorbuf);

static size_t append_str(char *buf, size_t size, size_t off, const char *s) {
  size_t n = strlen(s);
  if (off + n + 1 > size) {
    Rf_error("run_r sandbox: profile buffer overflow");
  }
  memcpy(buf + off, s, n + 1);
  return off + n;
}

static size_t append_subpaths(char *buf, size_t size, size_t off, SEXP roots) {
  for (int i = 0; i < Rf_length(roots); i++) {
    const char *path = CHAR(STRING_ELT(roots, i));
    if (strpbrk(path, "\"\\") != NULL) {
      Rf_error("cannot sandbox: root '%s' contains a quote or backslash",
               path);
    }
    off = append_str(buf, size, off, " (subpath \"");
    off = append_str(buf, size, off, path);
    off = append_str(buf, size, off, "\")");
  }
  return off;
}

SEXP c_sandbox_capabilities(void) {
  SEXP out = PROTECT(Rf_allocVector(INTSXP, 4));
  INTEGER(out)[0] = -1;
  INTEGER(out)[1] = 0;
  INTEGER(out)[2] = 1;
  INTEGER(out)[3] = 0;
  UNPROTECT(1);
  return out;
}

SEXP c_sandbox_engage(SEXP read_roots, SEXP rw_roots, SEXP memory_limit,
                      SEXP mode_sexp, SEXP preserve_fds, SEXP network_sexp) {
  /* Sandbox modes select Linux backends only. */
  (void) mode_sexp;
  (void) preserve_fds;
  const char *network = CHAR(STRING_ELT(network_sexp, 0));
  if (strcmp(network, "none") != 0 && strcmp(network, "full") != 0) {
    Rf_error("unknown network access level '%s'", network);
  }

  if (memory_limit != R_NilValue) {
    /* Accepted but not reliably enforced by the macOS kernel; kept for
     * interface parity with the Linux branch. */
    rlim_t bytes = (rlim_t) REAL(memory_limit)[0];
    struct rlimit lim = { .rlim_cur = bytes, .rlim_max = bytes };
    if (setrlimit(RLIMIT_AS, &lim) != 0) {
      Rf_error("setrlimit(RLIMIT_AS) failed: %s", strerror(errno));
    }
  }

  size_t size = 512;
  for (int i = 0; i < Rf_length(read_roots); i++) {
    size += strlen(CHAR(STRING_ELT(read_roots, i))) + 16;
  }
  for (int i = 0; i < Rf_length(rw_roots); i++) {
    size += 2 * (strlen(CHAR(STRING_ELT(rw_roots, i))) + 16);
  }
  char *profile = R_alloc(size, 1);

  /* Later rules take precedence in SBPL, so each filesystem deny is followed
   * by its allowlist; rw roots appear in both, mirroring Landlock's FS_V1_ALL.
   * file-read-metadata stays allowed for path traversal: it exposes existence
   * of files outside the roots, but not contents. */
  size_t off = append_str(profile, size, 0,
    "(version 1)\n"
    "(allow default)\n");
  if (strcmp(network, "none") == 0) {
    off = append_str(profile, size, off, "(deny network*)\n");
  }
  off = append_str(profile, size, off,
    "(deny file-write*)\n"
    "(allow file-write* (literal \"/dev/null\")");
  off = append_subpaths(profile, size, off, rw_roots);
  off = append_str(profile, size, off,
    ")\n"
    "(deny file-read*)\n"
    "(allow file-read*");
  off = append_subpaths(profile, size, off, read_roots);
  off = append_subpaths(profile, size, off, rw_roots);
  off = append_str(profile, size, off,
    ")\n"
    "(allow file-read-metadata)\n");

  char *err = NULL;
  if (sandbox_init(profile, 0, &err) != 0) {
    char msg[512];
    snprintf(msg, sizeof(msg), "%s", err ? err : "unknown error");
    if (err) {
      sandbox_free_error(err);
    }
    Rf_error("sandbox_init failed: %s", msg);
  }

  return Rf_mkString("seatbelt");
}

#else /* not __linux__ or __APPLE__ */

SEXP c_sandbox_capabilities(void) {
  SEXP out = PROTECT(Rf_allocVector(INTSXP, 4));
  INTEGER(out)[0] = -1;
  INTEGER(out)[1] = 0;
  INTEGER(out)[2] = 0;
  INTEGER(out)[3] = 0;
  UNPROTECT(1);
  return out;
}

SEXP c_sandbox_engage(SEXP read_roots, SEXP rw_roots, SEXP memory_limit,
                      SEXP mode_sexp, SEXP preserve_fds, SEXP network_sexp) {
  Rf_error("sandboxing is only supported on Linux and macOS");
  return R_NilValue;
}

#endif

static const R_CallMethodDef call_methods[] = {
  {"c_sandbox_capabilities", (DL_FUNC) &c_sandbox_capabilities, 0},
  {"c_sandbox_engage", (DL_FUNC) &c_sandbox_engage, 6},
  {NULL, NULL, 0}
};

void R_init_commons(DllInfo *dll) {
  R_registerRoutines(dll, NULL, call_methods, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
}
