/* Example for the libvaxis C API.
 *
 * Built and run as part of `zig build test`. Feeds a handful of terminal
 * escape sequences through the parser and checks the resulting events.
 */
#include <stdio.h>
#include <string.h>

#include <vaxis.h>

#define CHECK(cond)                                                          \
  do {                                                                       \
    if (!(cond)) {                                                           \
      fprintf(stderr, "FAILED: %s (%s:%d)\n", #cond, __FILE__, __LINE__);    \
      return 1;                                                              \
    }                                                                        \
  } while (0)

static vaxis_result parse(vaxis_parser *parser, const char *input,
                          const vaxis_event **event, size_t *consumed) {
  return vaxis_parser_parse(parser, (const uint8_t *)input, strlen(input),
                            event, consumed);
}

int main(void) {
  vaxis_parser *parser = vaxis_parser_new();
  CHECK(parser != NULL);

  const vaxis_event *event = NULL;
  size_t n = 0;

  /* Plain text keypress */
  CHECK(parse(parser, "a", &event, &n) == VAXIS_OK);
  CHECK(n == 1);
  CHECK(vaxis_event_get_type(event) == VAXIS_EVENT_KEY_PRESS);
  CHECK(vaxis_event_key_codepoint(event) == 'a');
  vaxis_string text = vaxis_event_key_text(event);
  CHECK(text.len == 1);
  CHECK(memcmp(text.ptr, "a", 1) == 0);
  CHECK(vaxis_event_key_matches(event, 'a', 0));

  /* Arrow key */
  CHECK(parse(parser, "\x1b[A", &event, &n) == VAXIS_OK);
  CHECK(n == 3);
  CHECK(vaxis_event_get_type(event) == VAXIS_EVENT_KEY_PRESS);
  CHECK(vaxis_event_key_codepoint(event) == VAXIS_KEY_UP);

  /* Kitty keyboard: shift+a with alternate codepoint reporting */
  CHECK(parse(parser, "\x1b[97:65;2u", &event, &n) == VAXIS_OK);
  CHECK(vaxis_event_get_type(event) == VAXIS_EVENT_KEY_PRESS);
  CHECK(vaxis_event_key_codepoint(event) == 'a');
  CHECK(vaxis_event_key_shifted_codepoint(event) == 'A');
  CHECK((vaxis_event_key_mods(event) & VAXIS_MOD_SHIFT) != 0);
  CHECK(vaxis_event_key_matches(event, 'a', VAXIS_MOD_SHIFT));

  /* SGR mouse motion */
  CHECK(parse(parser, "\x1b[<35;1;1m", &event, &n) == VAXIS_OK);
  CHECK(vaxis_event_get_type(event) == VAXIS_EVENT_MOUSE);
  CHECK(vaxis_event_mouse_col(event) == 0);
  CHECK(vaxis_event_mouse_row(event) == 0);
  CHECK(vaxis_event_mouse_button(event) == VAXIS_MOUSE_NONE);
  CHECK(vaxis_event_mouse_type(event) == VAXIS_MOUSE_MOTION);
  /* Accessors for other event types return zero values */
  CHECK(vaxis_event_key_codepoint(event) == 0);
  CHECK(vaxis_event_key_text(event).ptr == NULL);

  /* In-band window resize */
  CHECK(parse(parser, "\x1b[48;24;80;480;1440t", &event, &n) == VAXIS_OK);
  CHECK(vaxis_event_get_type(event) == VAXIS_EVENT_WINSIZE);
  CHECK(vaxis_event_winsize_rows(event) == 24);
  CHECK(vaxis_event_winsize_cols(event) == 80);
  CHECK(vaxis_event_winsize_x_pixel(event) == 1440);
  CHECK(vaxis_event_winsize_y_pixel(event) == 480);

  /* Background color report */
  CHECK(parse(parser, "\x1b]11;rgb:ffff/8080/0000\x1b\\", &event, &n) ==
        VAXIS_OK);
  CHECK(vaxis_event_get_type(event) == VAXIS_EVENT_COLOR_REPORT);
  CHECK(vaxis_event_color_report_kind(event) == VAXIS_COLOR_BG);
  vaxis_rgb rgb = vaxis_event_color_report_rgb(event);
  CHECK(rgb.r == 0xff && rgb.g == 0x80 && rgb.b == 0x00);

  /* OSC 52 paste; the text is parser-owned, nothing to free */
  CHECK(parse(parser, "\x1b]52;c;b3NjNTIgcGFzdGU=\x1b\\", &event, &n) ==
        VAXIS_OK);
  CHECK(vaxis_event_get_type(event) == VAXIS_EVENT_PASTE);
  vaxis_string paste = vaxis_event_paste_text(event);
  CHECK(paste.len == strlen("osc52 paste"));
  CHECK(memcmp(paste.ptr, "osc52 paste", paste.len) == 0);

  /* Focus events */
  CHECK(parse(parser, "\x1b[I", &event, &n) == VAXIS_OK);
  CHECK(vaxis_event_get_type(event) == VAXIS_EVENT_FOCUS_IN);
  CHECK(parse(parser, "\x1b[O", &event, &n) == VAXIS_OK);
  CHECK(vaxis_event_get_type(event) == VAXIS_EVENT_FOCUS_OUT);

  /* Incomplete sequence: no event, nothing consumed */
  CHECK(parse(parser, "\x1b[", &event, &n) == VAXIS_OK);
  CHECK(event == NULL);
  CHECK(vaxis_event_get_type(event) == VAXIS_EVENT_NONE);
  CHECK(n == 0);

  /* Malformed-but-recognized sequence: consumed with no event, not an
   * error */
  CHECK(parse(parser, "\x1b]4;1;rgb:zz/zz/zz\x1b\\", &event, &n) == VAXIS_OK);
  CHECK(event == NULL);
  CHECK(n == 20);

  /* Key name lookup */
  CHECK(vaxis_key_from_name("enter", 5) == VAXIS_KEY_ENTER);
  CHECK(vaxis_key_from_name("nope", 4) == 0);

  vaxis_parser_free(parser);
  printf("libvaxis %s: all C API checks passed\n", vaxis_version());
  return 0;
}
