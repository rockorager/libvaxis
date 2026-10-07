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
#include <string.h>
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

/* Reports reach the terminal through a runtime on the controlling TTY. */
static void test_program_status(void) {
  vaxis_tty *tty = NULL;
  vaxis_runtime *runtime = NULL;
  vaxis_runtime_options options = {NULL, 0};
  assert(vaxis_tty_new(&tty) == VAXIS_OK);
  assert(vaxis_runtime_new(tty, &options, &runtime) == VAXIS_OK);
  assert(!vaxis_runtime_capabilities(runtime).program_status);

  vaxis_program_status status = {
      VAXIS_PROGRAM_STATUS_BLOCKED, VAXIS_PROGRAM_STATUS_KIND_QUESTION,
      {(const uint8_t *)"build/test", 10}, {(const uint8_t *)"make", 4},
      {NULL, 0}, {(const uint8_t *)"Continue?", 9}, 40, true};
  assert(vaxis_runtime_report_program_status(runtime, &status) == VAXIS_OK);
  status.app.len = 0; /* non-NULL and empty is invalid */
  assert(vaxis_runtime_report_program_status(runtime, &status) ==
         VAXIS_ERR_INVALID);
  assert(vaxis_runtime_report_program_status(runtime, NULL) ==
         VAXIS_ERR_INVALID);
  assert(vaxis_runtime_clear_program_status(runtime, (const uint8_t *)"build",
                                            5) == VAXIS_OK);
  assert(vaxis_runtime_clear_program_status(runtime, NULL, 0) == VAXIS_OK);
  vaxis_runtime_free(runtime);
  vaxis_tty_free(tty);
}

static bool contains(const char *haystack, size_t len, const char *needle) {
  size_t n = strlen(needle);
  for (size_t i = 0; n <= len && i <= len - n; ++i)
    if (memcmp(haystack + i, needle, n) == 0) return true;
  return false;
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
  /* Hold the slave open so output stays readable after the child exits. */
  int parent_slave = open(slave_name, O_RDWR | O_NOCTTY);
  assert(parent_slave >= 0);
  pid_t child = fork();
  assert(child >= 0);
  if (child == 0) {
    alarm(15);
    assert(setsid() >= 0);
    int slave = open(slave_name, O_RDWR);
    assert(slave >= 0);
    assert(ioctl(slave, TIOCSCTTY, 0) == 0);
    close(master);
    close(parent_slave);
    test_tty();
    test_program_status();
    close(slave);
    _exit(0);
  }
  int status;
  assert(waitpid(child, &status, 0) == child);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

  char output[4096];
  size_t len = 0;
  assert(fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK) == 0);
  for (;;) {
    ssize_t n = read(master, output + len, sizeof(output) - len);
    if (n <= 0) break;
    len += (size_t)n;
  }
  close(parent_slave);
  close(master);
  assert(contains(output, len,
                  "\x1b]7501;state=blocked:id=build/test:kind=question:"
                  "progress=40:app=make:msg=Q29udGludWU/\x1b\\"));
  assert(contains(output, len, "\x1b]7501;state=clear:id=build\x1b\\"));
  assert(contains(output, len, "\x1b]7501;state=clear\x1b\\"));
  puts("C TTY SIGWINCH and program status checks passed");
  return 0;
}
#endif
