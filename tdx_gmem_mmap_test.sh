#!/usr/bin/env bash
# tdx_gmem_mmap_test.sh (v3 - location-agnostic)
#
# Validate that a TDX guest_memfd cannot be mmap()'d from host user space.
#
# Strategy: use pidfd_open(2)+pidfd_getfd(2) to duplicate the QEMU
# guest_memfd fd into our own process, then try mmap() with three prot/flags
# combos.  No gdb, no ptrace, no /proc/<pid>/fd/ magic-link open.
#
# The script self-contains a small C helper.  All working files (helper
# source, compiled binary, log) are created in a private temporary
# directory chosen at runtime, so the script itself may live anywhere.
#
# Precedence for the working directory:
#   1. $TDX_GMEM_WORKDIR if set
#   2. -w <dir> option
#   3. mktemp -d under $TMPDIR (defaults to /tmp)
#
# Usage:
#   sudo ./tdx_gmem_mmap_test.sh [-p <qemu_pid>] [-f <fd>] [-w <workdir>] [-l <log>] [-k]
#     -p   QEMU pid (auto-detect via 'pidof qemu-system-x86_64' if omitted)
#     -f   guest_memfd fd under /proc/<pid>/fd/ (auto-detect if omitted)
#     -w   working directory (helper source/binary/log)
#     -l   explicit log file path (overrides workdir default)
#     -k   keep working directory on exit (default: remove non-log files)
#     -h   show help
#
# Exit codes:
#   0 = PASS (all 3 mmap attempts rejected)
#   1 = FAIL (at least one mmap succeeded)
#   2 = env/usage error / could not run test

set -u

PID=""
FD=""
WORKDIR="${TDX_GMEM_WORKDIR:-}"
LOG=""
KEEP=0

usage() {
    sed -n '2,32p' "$0"
}

while getopts "p:f:w:l:kh" opt; do
    case "$opt" in
        p) PID="$OPTARG" ;;
        f) FD="$OPTARG" ;;
        w) WORKDIR="$OPTARG" ;;
        l) LOG="$OPTARG" ;;
        k) KEEP=1 ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

# ---- resolve working directory ----
if [ -z "$WORKDIR" ]; then
    WORKDIR=$(mktemp -d -t tdx_gmem_mmap.XXXXXX) || {
        echo "ERROR: mktemp -d failed" >&2; exit 2; }
    OWN_WORKDIR=1
else
    mkdir -p "$WORKDIR" || { echo "ERROR: cannot create $WORKDIR" >&2; exit 2; }
    OWN_WORKDIR=0
fi
HELPER_SRC="$WORKDIR/tdx_gmem_try_mmap.c"
HELPER_BIN="$WORKDIR/tdx_gmem_try_mmap"
if [ -z "$LOG" ]; then
    LOG="$WORKDIR/tdx_gmem_mmap_$(date +%Y%m%d_%H%M%S).log"
fi
echo "workdir = $WORKDIR"
echo "log     = $LOG"

cleanup() {
    rc=$?
    if [ "$KEEP" -eq 0 ] && [ "$OWN_WORKDIR" -eq 1 ]; then
        # keep the log by moving it next to CWD if it's inside the workdir
        if [ -f "$LOG" ] && [ "${LOG#$WORKDIR}" != "$LOG" ]; then
            outlog="$(pwd)/$(basename "$LOG")"
            cp -f "$LOG" "$outlog" 2>/dev/null && \
                echo "log copied to: $outlog"
        fi
        rm -rf "$WORKDIR"
    fi
    exit $rc
}
trap cleanup EXIT

# ---- root check ----
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root." >&2
    exit 2
fi

# ---- toolchain ----
if ! command -v gcc >/dev/null 2>&1; then
    echo "ERROR: gcc not found. Install: yum install -y gcc  /  apt-get install -y gcc" >&2
    exit 2
fi

# ---- PID ----
if [ -z "$PID" ]; then
    PID=$(pidof qemu-system-x86_64 2>/dev/null | awk '{print $1}')
fi
if [ -z "$PID" ] || [ ! -d "/proc/$PID" ]; then
    echo "ERROR: cannot resolve QEMU pid; pass -p <pid>" >&2
    exit 2
fi
echo "PID = $PID"

# ---- locate guest_memfd fd ----
# Match both new-style ('anon_inode:[kvm-gmem]') and old-style
# ('/[kvm-gmem] (deleted)') symlink targets.
if [ -z "$FD" ]; then
    echo "scanning /proc/$PID/fd/ for guest_memfd ..."
    for f in /proc/"$PID"/fd/*; do
        tgt=$(readlink "$f" 2>/dev/null) || continue
        case "$tgt" in
            *kvm-gmem*|*guest_memfd*|*kvm-guest-memfd*)
                FD="$(basename "$f")"
                echo "found guest_memfd: $f -> $tgt"
                break
                ;;
        esac
    done
fi
if [ -z "$FD" ] || [ ! -e "/proc/$PID/fd/$FD" ]; then
    echo "ERROR: no guest_memfd fd found under /proc/$PID/fd/" >&2
    echo "       Ensure QEMU launched with -object tdx-guest,... and memory-backend ...,private=on" >&2
    exit 2
fi
echo "FD  = $FD"
echo "target: /proc/$PID/fd/$FD -> $(readlink /proc/"$PID"/fd/"$FD")"

# ---- build C helper ----
cat > "$HELPER_SRC" <<'CEOF'
/* Try three mmap() combos against a guest_memfd owned by another process.
 * Uses pidfd_open(2) + pidfd_getfd(2) to duplicate the fd -- the /proc
 * magic-link path doesn't work for anonymous inodes like guest_memfd.  */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <linux/types.h>

#ifndef __NR_pidfd_open
#define __NR_pidfd_open  434
#endif
#ifndef __NR_pidfd_getfd
#define __NR_pidfd_getfd 438
#endif

static int sys_pidfd_open(pid_t pid, unsigned int flags)
{
    return (int)syscall(__NR_pidfd_open, pid, flags);
}
static int sys_pidfd_getfd(int pidfd, int targetfd, unsigned int flags)
{
    return (int)syscall(__NR_pidfd_getfd, pidfd, targetfd, flags);
}

static void try_one(const char *tag, int fd, int prot, int flags)
{
    errno = 0;
    void *p = mmap(NULL, 4096, prot, flags, fd, 0);
    int  e  = errno;
    if (p == MAP_FAILED) {
        printf("[%-7s] mmap ret = 0xffffffffffffffff  errno = %d (%s)\n",
               tag, e, strerror(e));
    } else {
        printf("[%-7s] mmap ret = %p  errno = 0 (Success) -- UNEXPECTED\n",
               tag, p);
        munmap(p, 4096);
    }
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s <pid> <fd>\n", argv[0]);
        return 2;
    }
    pid_t pid = (pid_t)atoi(argv[1]);
    int   tfd = atoi(argv[2]);

    int pidfd = sys_pidfd_open(pid, 0);
    if (pidfd < 0) {
        fprintf(stderr, "pidfd_open(%d): %s\n", pid, strerror(errno));
        return 2;
    }
    int fd = sys_pidfd_getfd(pidfd, tfd, 0);
    if (fd < 0) {
        fprintf(stderr, "pidfd_getfd(pidfd=%d, tfd=%d): %s\n",
                pidfd, tfd, strerror(errno));
        close(pidfd);
        return 2;
    }
    printf("duplicated guest_memfd from pid=%d fd=%d into local fd=%d\n",
           pid, tfd, fd);

    try_one("SHARED",  fd, PROT_READ|PROT_WRITE, MAP_SHARED);
    try_one("PRIVATE", fd, PROT_READ|PROT_WRITE, MAP_PRIVATE);
    try_one("RDONLY",  fd, PROT_READ,            MAP_SHARED);

    close(fd);
    close(pidfd);
    return 0;
}
CEOF

echo "compiling helper ..."
gcc -O2 -Wall -o "$HELPER_BIN" "$HELPER_SRC"
echo "helper: $HELPER_BIN"

# ---- run and capture ----
echo "running ..."
"$HELPER_BIN" "$PID" "$FD" 2>&1 | tee "$LOG"
echo
echo "log saved to: $LOG"

# ---- parse ----
attempts=$(grep -cE '^\[(SHARED|PRIVATE|RDONLY)' "$LOG" || true)
succeeded=$(grep -c 'UNEXPECTED' "$LOG" || true)

echo
echo "== summary =="
grep -E '^\[(SHARED|PRIVATE|RDONLY)' "$LOG" || true
echo "attempts=$attempts  succeeded_unexpectedly=$succeeded"

if [ "$attempts" -ne 3 ]; then
    echo "RESULT: INCONCLUSIVE  (expected 3 mmap lines, got $attempts). See $LOG"
    exit 2
fi
if [ "$succeeded" -eq 0 ]; then
    echo "RESULT: PASS  (guest_memfd rejected all mmap() attempts)"
    exit 0
else
    echo "RESULT: FAIL  ($succeeded mmap() call(s) unexpectedly succeeded -- isolation broken)"
    exit 1
fi
