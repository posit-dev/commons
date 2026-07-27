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

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/audit.h>
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

#define LL_CREATE_RULESET_VERSION (1U << 0)
#define LL_RULE_PATH_BENEATH 1

/* Landlock ABI v1 filesystem access rights: the 13 rights every
 * Landlock-enabled kernel understands. Later ABIs add rights we leave
 * unhandled, which the kernel treats at least as restrictively. */
#define FS_EXECUTE (1ULL << 0)
#define FS_READ_FILE (1ULL << 2)
#define FS_READ_DIR (1ULL << 3)
#define FS_V1_ALL ((1ULL << 13) - 1)
#define FS_READ_ONLY (FS_EXECUTE | FS_READ_FILE | FS_READ_DIR)

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

SEXP c_sandbox_capabilities(void) {
  long landlock_abi = syscall(__NR_landlock_create_ruleset, NULL, 0,
                              LL_CREATE_RULESET_VERSION);
  int seccomp_ok = prctl(PR_GET_SECCOMP, 0, 0, 0, 0) >= 0;
  SEXP out = PROTECT(Rf_allocVector(INTSXP, 3));
  INTEGER(out)[0] = (int) landlock_abi;
  INTEGER(out)[1] = seccomp_ok;
  INTEGER(out)[2] = 0;
  UNPROTECT(1);
  return out;
}

SEXP c_sandbox_engage(SEXP read_roots, SEXP rw_roots, SEXP memory_limit) {
  if (memory_limit != R_NilValue) {
    rlim_t bytes = (rlim_t) REAL(memory_limit)[0];
    struct rlimit lim = { .rlim_cur = bytes, .rlim_max = bytes };
    if (setrlimit(RLIMIT_AS, &lim) != 0) {
      Rf_error("setrlimit(RLIMIT_AS) failed: %s", strerror(errno));
    }
  }

  struct ll_ruleset_attr attr = { .handled_access_fs = FS_V1_ALL };
  int fd = (int) syscall(__NR_landlock_create_ruleset, &attr, sizeof(attr), 0);
  if (fd < 0) {
    Rf_error("landlock_create_ruleset failed: %s", strerror(errno));
  }
  add_roots(fd, read_roots, FS_READ_ONLY, "read");
  add_roots(fd, rw_roots, FS_V1_ALL, "read-write");

  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) {
    close(fd);
    Rf_error("prctl(PR_SET_NO_NEW_PRIVS) failed: %s", strerror(errno));
  }
  if (syscall(__NR_landlock_restrict_self, fd, 0)) {
    close(fd);
    Rf_error("landlock_restrict_self failed: %s", strerror(errno));
  }
  close(fd);

  /* No network, and no reading other processes' memory: the parent holds
   * credentials the worker must never see. */
  struct sock_filter filt[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (uint32_t) offsetof(struct seccomp_data, arch)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SANDBOX_AUDIT_ARCH, 1, 0),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (uint32_t) offsetof(struct seccomp_data, nr)),
#ifdef SANDBOX_X32_SYSCALL_BIT
    /* x32 syscalls share the x86_64 arch tag but set a high bit and index a
     * separate table, so screen them out before the number comparisons. */
    BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, SANDBOX_X32_SYSCALL_BIT, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
#endif
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socket, 4, 0),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_ptrace, 3, 0),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_process_vm_readv, 2, 0),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_process_vm_writev, 1, 0),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
  };
  struct sock_fprog prog = {
    .len = sizeof(filt) / sizeof(filt[0]),
    .filter = filt
  };
  if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog)) {
    Rf_error("seccomp filter install failed: %s", strerror(errno));
  }

  return R_NilValue;
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
  SEXP out = PROTECT(Rf_allocVector(INTSXP, 3));
  INTEGER(out)[0] = -1;
  INTEGER(out)[1] = 0;
  INTEGER(out)[2] = 1;
  UNPROTECT(1);
  return out;
}

SEXP c_sandbox_engage(SEXP read_roots, SEXP rw_roots, SEXP memory_limit) {
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

  /* Later rules take precedence in SBPL, so each blanket deny is followed by
   * its allowlist; rw roots appear in both, mirroring Landlock's FS_V1_ALL.
   * (deny network*) covers unix-domain sockets too, blocking DNS via
   * mDNSResponder — parity with seccomp's blanket socket() denial.
   * file-read-metadata stays allowed for path traversal: it exposes
   * existence of files outside the roots, but not contents. */
  size_t off = append_str(profile, size, 0,
    "(version 1)\n"
    "(allow default)\n"
    "(deny network*)\n"
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

  return R_NilValue;
}

#else /* not __linux__ or __APPLE__ */

SEXP c_sandbox_capabilities(void) {
  SEXP out = PROTECT(Rf_allocVector(INTSXP, 3));
  INTEGER(out)[0] = -1;
  INTEGER(out)[1] = 0;
  INTEGER(out)[2] = 0;
  UNPROTECT(1);
  return out;
}

SEXP c_sandbox_engage(SEXP read_roots, SEXP rw_roots, SEXP memory_limit) {
  Rf_error("sandboxing is only supported on Linux and macOS");
  return R_NilValue;
}

#endif

static const R_CallMethodDef call_methods[] = {
  {"c_sandbox_capabilities", (DL_FUNC) &c_sandbox_capabilities, 0},
  {"c_sandbox_engage", (DL_FUNC) &c_sandbox_engage, 3},
  {NULL, NULL, 0}
};

void R_init_commons(DllInfo *dll) {
  R_registerRoutines(dll, NULL, call_methods, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
}
