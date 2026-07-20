/* Self-restriction bindings for the run_r worker process. These run once at
 * worker startup; enforcement thereafter is the kernel's, not this code's.
 * Landlock has no libc wrapper and seccomp requires prctl() with a BPF
 * program, so neither is reachable from R without this layer. */

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
#include <linux/filter.h>
#include <linux/seccomp.h>

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
  SEXP out = PROTECT(Rf_allocVector(INTSXP, 2));
  INTEGER(out)[0] = (int) landlock_abi;
  INTEGER(out)[1] = seccomp_ok;
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
             (uint32_t) offsetof(struct seccomp_data, nr)),
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

#else /* not __linux__ */

SEXP c_sandbox_capabilities(void) {
  SEXP out = PROTECT(Rf_allocVector(INTSXP, 2));
  INTEGER(out)[0] = -1;
  INTEGER(out)[1] = 0;
  UNPROTECT(1);
  return out;
}

SEXP c_sandbox_engage(SEXP read_roots, SEXP rw_roots, SEXP memory_limit) {
  Rf_error("sandboxing is only supported on Linux");
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
