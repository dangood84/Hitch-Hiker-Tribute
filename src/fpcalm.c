/* Clears Pascal's floating-point traps.

   Metal draws the frame on a thread of its own. Pascal turns overflow
   traps on, Metal multiplies FLT_MAX by 64, and the tube dies on the
   first frame. New threads are cleared as they start. If a thread turns
   the traps back on and then faults, the signal handler clears them and
   lets that instruction run again. */

#include <signal.h>
#include <stdint.h>
#include <sys/ucontext.h>

typedef void (*fp_hook)(unsigned int event, void *thread, void *addr, unsigned long size);

extern fp_hook pthread_introspection_hook_install(fp_hook hook);

static __thread int calmed;

static void clear_traps(void) {
  uint64_t fpcr;
  __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
  fpcr &= ~0x9f00ull; /* IOE DZE OFE UFE IXE IDE */
  __asm__ volatile("msr fpcr, %0" :: "r"(fpcr));
}

static void on_thread(unsigned int event, void *thread, void *addr, unsigned long size) {
  (void)thread;
  (void)addr;
  (void)size;
  if (event == 2) /* PTHREAD_INTROSPECTION_THREAD_START */
    clear_traps();
}

static void on_trap(int sig, siginfo_t *info, void *ctx) {
  ucontext_t *uc = ctx;
  (void)sig;
  (void)info;
  if (!calmed && uc && uc->uc_mcontext) {
    calmed = 1;
    /* The kernel restores fpcr from this context, so the live
       register is not enough: the trap bits would come back. */
    uc->uc_mcontext->__ns.__fpcr &= ~0x9f00u;
    clear_traps();
    return;
  }
  signal(sig, SIG_DFL);
  raise(sig);
}

static void catch_trap(int sig) {
  struct sigaction sa;
  sa.sa_sigaction = on_trap;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigaction(sig, &sa, 0);
}

void InstallFpCalm(void) {
  pthread_introspection_hook_install(on_thread);
  clear_traps();
  catch_trap(SIGILL);
  catch_trap(SIGFPE);
}
