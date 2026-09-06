#define _XOPEN_SOURCE 600
#define _DARWIN_C_SOURCE
#include <vaxis.h>
#include <assert.h>
#include <stdio.h>

#ifdef _WIN32
int main(void) {
  assert(vaxis_tty_notify_winsize(NULL, NULL, NULL) == VAXIS_ERR_UNSUPPORTED);
  assert(vaxis_tty_remove_winsize_notify(NULL, NULL, NULL) == VAXIS_ERR_UNSUPPORTED);
  return 0;
}
#else
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

static int notifications[2];

/* A pipe wakes the event loop without sharing mutable state with dispatch. */
static void resized(void *context) {
  const char value = context ? *(const char *)context : '0';
  assert(write(notifications[1], &value, 1) == 1);
}

static void other_resized(void *context) {
  (void)context;
  const char value = 'x';
  assert(write(notifications[1], &value, 1) == 1);
}

static int ready(int timeout) {
  struct pollfd fd = {notifications[0], POLLIN, 0};
  int rc;
  do { rc = poll(&fd, 1, timeout); } while (rc < 0 && errno == EINTR);
  assert(rc >= 0);
  return rc;
}

static void expect_resize(const char *expected) {
  assert(kill(getpid(), SIGWINCH) == 0);
  for (; *expected; ++expected) {
    char value;
    assert(ready(2000) == 1);
    assert(read(notifications[0], &value, 1) == 1);
    assert(value == *expected);
  }
  assert(ready(30) == 0);
}

static void test_tty(void) {
  vaxis_tty *tty = NULL;
  char a = 'a', b = 'b';
  assert(pipe(notifications) == 0);
  assert(vaxis_tty_new(&tty) == VAXIS_OK);
  assert(vaxis_tty_notify_winsize(NULL, resized, &a) == VAXIS_ERR_INVALID);
  assert(vaxis_tty_notify_winsize(tty, NULL, &a) == VAXIS_ERR_INVALID);
  assert(vaxis_tty_remove_winsize_notify(NULL, resized, &a) == VAXIS_ERR_INVALID);
  assert(vaxis_tty_remove_winsize_notify(tty, NULL, &a) == VAXIS_ERR_INVALID);

  assert(vaxis_tty_notify_winsize(tty, resized, &a) == VAXIS_OK);
  assert(vaxis_tty_notify_winsize(tty, resized, &b) == VAXIS_OK);
  assert(vaxis_tty_notify_winsize(tty, other_resized, &a) == VAXIS_OK);
  assert(vaxis_tty_notify_winsize(tty, resized, NULL) == VAXIS_OK);
  expect_resize("abx0");

  /* Removal matches both callback and context, and absent removal is a no-op. */
  assert(vaxis_tty_remove_winsize_notify(tty, resized, &a) == VAXIS_OK);
  assert(vaxis_tty_remove_winsize_notify(tty, resized, &a) == VAXIS_OK);
  expect_resize("bx0");
  assert(vaxis_tty_remove_winsize_notify(tty, resized, &b) == VAXIS_OK);
  assert(vaxis_tty_remove_winsize_notify(tty, other_resized, &a) == VAXIS_OK);
  assert(vaxis_tty_remove_winsize_notify(tty, resized, NULL) == VAXIS_OK);
  expect_resize("");

  /* Re-register after removing the last callback, then exercise the limit,
   * duplicates, removal of one duplicate, and reuse of the released slot. */
  for (int i = 0; i < 8; ++i)
    assert(vaxis_tty_notify_winsize(tty, resized, &a) == VAXIS_OK);
  assert(vaxis_tty_notify_winsize(tty, resized, &b) == VAXIS_ERR_OOM);
  expect_resize("aaaaaaaa");
  assert(vaxis_tty_remove_winsize_notify(tty, resized, &a) == VAXIS_OK);
  assert(vaxis_tty_notify_winsize(tty, resized, &b) == VAXIS_OK);
  expect_resize("aaaaaaab");

  /* Free with live subscriptions, then open again: no stale registrations. */
  vaxis_tty_free(tty);
  expect_resize("");
  assert(vaxis_tty_new(&tty) == VAXIS_OK);
  assert(vaxis_tty_notify_winsize(tty, resized, &b) == VAXIS_OK);
  expect_resize("b");
  vaxis_tty_free(tty);
  close(notifications[0]);
  close(notifications[1]);
}

int main(void) {
  /* Give the child its own controlling terminal, even in headless CI. Keep
   * the master open in the parent until the child has finished. */
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  assert(master >= 0);
  assert(grantpt(master) == 0);
  assert(unlockpt(master) == 0);
  const char *slave_name = ptsname(master);
  assert(slave_name);
  pid_t child = fork();
  assert(child >= 0);
  if (child == 0) {
    alarm(15);
    assert(setsid() >= 0);
    int slave = open(slave_name, O_RDWR);
    assert(slave >= 0);
    assert(ioctl(slave, TIOCSCTTY, 0) == 0);
    close(master);
    test_tty();
    close(slave);
    _exit(0);
  }
  int status;
  assert(waitpid(child, &status, 0) == child);
  close(master);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  puts("C TTY SIGWINCH checks passed");
  return 0;
}
#endif
