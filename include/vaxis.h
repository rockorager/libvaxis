/* libvaxis C API
 *
 * Stable C ABI for the vaxis terminal runtime.
 *
 * All objects are opaque handles. Unless stated otherwise, handles and their
 * children are confined to the creating thread. NULL may be passed to every
 * *_free function; other functions reject NULL with VAXIS_ERR_INVALID.
 * Events are opaque handles read through vaxis_event_* accessors. Event
 * data is owned by the parser and valid until the next parse call on that
 * parser; the caller never frees anything. Copy what you need longer.
 *
 * Build with `zig build lib`, which produces libvaxis.a / libvaxis.so and
 * installs this header. Use `zig build lib-static` or `zig build lib-shared`
 * when only one linkage is needed.
 */

#ifndef VAXIS_H
#define VAXIS_H

#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Force a fixed underlying type on enums where the compiler supports it so
 * that enum values have a stable ABI regardless of consumer compiler flags
 * (e.g. -fshort-enums). Where it isn't supported, the VAXIS_ENUM_MAX_VALUE
 * sentinel member pins the enum to int width. */
#if defined(__cplusplus) && \
    (__cplusplus >= 201103L || (defined(_MSC_VER) && _MSC_VER >= 1700))
#define VAXIS_ENUM_TYPED : int
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#define VAXIS_ENUM_TYPED : int
#elif defined(__clang__) && !defined(__STRICT_ANSI__)
#if __has_extension(c_fixed_enum)
#define VAXIS_ENUM_TYPED : int
#else
#define VAXIS_ENUM_TYPED
#endif
#elif defined(__GNUC__) && __GNUC__ >= 13
#define VAXIS_ENUM_TYPED : int
#else
#define VAXIS_ENUM_TYPED
#endif
#define VAXIS_ENUM_MAX_VALUE INT_MAX

/* Return codes. Zero is success; errors are negative. */
typedef enum VAXIS_ENUM_TYPED {
  VAXIS_OK = 0,
  VAXIS_ERR_INVALID = -1, /* invalid argument (e.g. NULL pointer) */
  VAXIS_ERR_OOM = -2, /* out of memory */
  /* Reserved: the current parser substitutes invalid UTF-8 rather than
   * reporting it, so this code is not produced today. */
  VAXIS_ERR_INVALID_UTF8 = -3,
  VAXIS_ERR_IO = -4,
  VAXIS_ERR_UNSUPPORTED = -5,
  VAXIS_ERR_RANGE = -6,
  VAXIS_ERR_STATE = -7,

  /* Sentinel to pin the enum to int width; never produced. */
  VAXIS_RESULT_MAX_VALUE = VAXIS_ENUM_MAX_VALUE,
} vaxis_result;

/* Event types */
typedef enum VAXIS_ENUM_TYPED {
  VAXIS_EVENT_NONE = 0,
  VAXIS_EVENT_KEY_PRESS = 1,
  VAXIS_EVENT_KEY_RELEASE = 2,
  VAXIS_EVENT_MOUSE = 3,
  VAXIS_EVENT_MOUSE_LEAVE = 4,
  VAXIS_EVENT_FOCUS_IN = 5,
  VAXIS_EVENT_FOCUS_OUT = 6,
  VAXIS_EVENT_PASTE_START = 7, /* bracketed paste start */
  VAXIS_EVENT_PASTE_END = 8, /* bracketed paste end */
  VAXIS_EVENT_PASTE = 9, /* OSC 52 paste */
  VAXIS_EVENT_COLOR_REPORT = 10, /* OSC 4/10/11/12 response */
  VAXIS_EVENT_COLOR_SCHEME = 11, /* light/dark scheme report */
  VAXIS_EVENT_WINSIZE = 12, /* in-band window resize */

  /* Discovered terminal capabilities */
  VAXIS_EVENT_CAP_KITTY_KEYBOARD = 13,
  VAXIS_EVENT_CAP_KITTY_GRAPHICS = 14,
  VAXIS_EVENT_CAP_RGB = 15,
  VAXIS_EVENT_CAP_SGR_PIXELS = 16,
  VAXIS_EVENT_CAP_UNICODE = 17,
  VAXIS_EVENT_CAP_DA1 = 18,
  VAXIS_EVENT_CAP_COLOR_SCHEME_UPDATES = 19,
  VAXIS_EVENT_CAP_MULTI_CURSOR = 20,

  /* Sentinel to pin the enum to int width; never produced. */
  VAXIS_EVENT_TYPE_MAX_VALUE = VAXIS_ENUM_MAX_VALUE,
} vaxis_event_type;

/* Key modifier bits (vaxis_event_key_mods) */
#define VAXIS_MOD_SHIFT (1 << 0)
#define VAXIS_MOD_ALT (1 << 1)
#define VAXIS_MOD_CTRL (1 << 2)
#define VAXIS_MOD_SUPER (1 << 3)
#define VAXIS_MOD_HYPER (1 << 4)
#define VAXIS_MOD_META (1 << 5)
#define VAXIS_MOD_CAPS_LOCK (1 << 6)
#define VAXIS_MOD_NUM_LOCK (1 << 7)

/* Mouse buttons (vaxis_event_mouse_button) */
#define VAXIS_MOUSE_LEFT 0
#define VAXIS_MOUSE_MIDDLE 1
#define VAXIS_MOUSE_RIGHT 2
#define VAXIS_MOUSE_NONE 3
#define VAXIS_MOUSE_WHEEL_UP 64
#define VAXIS_MOUSE_WHEEL_DOWN 65
#define VAXIS_MOUSE_WHEEL_RIGHT 66
#define VAXIS_MOUSE_WHEEL_LEFT 67
#define VAXIS_MOUSE_BUTTON_8 128
#define VAXIS_MOUSE_BUTTON_9 129
#define VAXIS_MOUSE_BUTTON_10 130
#define VAXIS_MOUSE_BUTTON_11 131

/* Mouse event types (vaxis_event_mouse_type) */
#define VAXIS_MOUSE_PRESS 0
#define VAXIS_MOUSE_RELEASE 1
#define VAXIS_MOUSE_MOTION 2
#define VAXIS_MOUSE_DRAG 3

/* Mouse modifier bits (vaxis_event_mouse_mods) */
#define VAXIS_MOUSE_MOD_SHIFT (1 << 0)
#define VAXIS_MOUSE_MOD_ALT (1 << 1)
#define VAXIS_MOUSE_MOD_CTRL (1 << 2)

/* Color report kinds (vaxis_event_color_report_kind) */
#define VAXIS_COLOR_FG 0
#define VAXIS_COLOR_BG 1
#define VAXIS_COLOR_CURSOR 2
#define VAXIS_COLOR_INDEX 3

/* Color schemes (vaxis_event_color_scheme) */
#define VAXIS_COLOR_SCHEME_DARK 0
#define VAXIS_COLOR_SCHEME_LIGHT 1

/* A borrowed byte slice. `ptr` is NULL when empty. */
typedef struct {
  const uint8_t *ptr;
  size_t len;
} vaxis_string;

/* Optional Zig-compatible allocator interface. Passing NULL to any allocator
 * parameter selects libvaxis's libc allocator. All callbacks are required.
 * `alignment` is a power-of-two byte alignment between 1 and 16.
 * `memory_len` and `alignment` exactly match the most recent successful
 * allocation/resize/remap. A custom
 * allocator's context and vtable must outlive every handle created with it and
 * must be safe to call from library worker threads.
 *
 * resize changes size in place and returns whether it succeeded. remap may
 * relocate and returns NULL when the caller should allocate/copy/free instead.
 */
typedef struct {
  void *(*alloc)(void *ctx, size_t len, uint8_t alignment,
                 uintptr_t return_address);
  bool (*resize)(void *ctx, void *memory, size_t memory_len,
                 uint8_t alignment, size_t new_len,
                 uintptr_t return_address);
  void *(*remap)(void *ctx, void *memory, size_t memory_len,
                 uint8_t alignment, size_t new_len,
                 uintptr_t return_address);
  void (*free)(void *ctx, void *memory, size_t memory_len,
               uint8_t alignment, uintptr_t return_address);
} vaxis_allocator_vtable;
typedef struct {
  void *ctx;
  const vaxis_allocator_vtable *vtable;
} vaxis_allocator;

/* Malloc/free-style helpers. Use the same allocator and exact length for both.
 * vaxis_free(NULL pointer) is a no-op. A zero-length allocation returns NULL. */
uint8_t *vaxis_alloc(const vaxis_allocator *allocator, size_t len);
void vaxis_free(const vaxis_allocator *allocator, uint8_t *ptr, size_t len);

/* Environment entry copied by runtime/terminal constructors. The key must be
 * non-empty and must not contain NUL or '='. Values must not contain NUL. */
typedef struct {
  vaxis_string key;
  vaxis_string value;
} vaxis_env_var;

/* An RGB color value. */
typedef struct {
  uint8_t r;
  uint8_t g;
  uint8_t b;
} vaxis_rgb;

/* An opaque terminal input parser. Not thread-safe: use one parser per input
 * stream. Parsed events are owned by the parser. */
typedef struct vaxis_parser vaxis_parser;
typedef struct vaxis_event vaxis_event;

/* ABI-stable value types. Strings are byte strings and need not be NUL
 * terminated. Input strings are borrowed for the duration of a call. */
typedef struct { uint16_t rows, cols, x_pixel, y_pixel; } vaxis_winsize;
typedef enum VAXIS_ENUM_TYPED {
  VAXIS_COLOR_DEFAULT = 0, VAXIS_COLOR_INDEXED = 1, VAXIS_COLOR_RGB = 2,
  VAXIS_COLOR_TYPE_MAX_VALUE = VAXIS_ENUM_MAX_VALUE,
} vaxis_color_type;
typedef struct { int32_t type; uint8_t index, r, g, b; } vaxis_color;
typedef struct {
  vaxis_color fg, bg, ul;
  uint8_t underline; /* 0 off, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed */
  uint8_t attrs; /* bit 0 bold, 1 dim, 2 italic, 3 blink, 4 reverse,
                    5 invisible, 6 strikethrough */
} vaxis_style;
typedef struct { vaxis_string grapheme; uint8_t width; vaxis_style style; } vaxis_cell;
typedef struct { vaxis_string text; vaxis_style style; } vaxis_segment;
typedef struct { uint16_t col, row; bool overflow; } vaxis_print_result;
typedef enum VAXIS_ENUM_TYPED {
  VAXIS_WRAP_GRAPHEME = 0, VAXIS_WRAP_WORD = 1, VAXIS_WRAP_NONE = 2,
  VAXIS_WRAP_MAX_VALUE = VAXIS_ENUM_MAX_VALUE,
} vaxis_wrap;
typedef struct { uint16_t row_offset, col_offset; int32_t wrap; bool commit; } vaxis_print_options;
typedef struct {
  int32_t x, y; uint16_t width, height;
  uint8_t border; /* bits: top=1, right=2, bottom=4, left=8 */
  vaxis_style border_style;
} vaxis_window_options;
typedef struct {
  bool kitty_keyboard, kitty_graphics, no_color, rgb, sgr_pixels;
  bool color_scheme_updates, explicit_width, scaled_text, multi_cursor;
  uint8_t unicode_width; /* 0=wcwidth, 1=unicode, 2=no_zwj */
} vaxis_capabilities;

typedef struct vaxis_screen vaxis_screen;
typedef struct vaxis_window vaxis_window;
typedef struct vaxis_text_input vaxis_text_input;
typedef struct vaxis_terminal vaxis_terminal;
typedef struct vaxis_image vaxis_image;
typedef struct vaxis_tty vaxis_tty;
typedef struct vaxis_runtime vaxis_runtime;

/* Screen owns cells and every window created from it. Free all windows before
 * freeing or resizing their screen. Cell/string values returned by read_cell
 * are borrowed until the next mutation of that screen. */
vaxis_result vaxis_screen_new(vaxis_winsize size, vaxis_screen **screen);
vaxis_result vaxis_screen_new_with_allocator(const vaxis_allocator *allocator,
                                             vaxis_winsize size,
                                             vaxis_screen **screen);
void vaxis_screen_free(vaxis_screen *screen);
vaxis_result vaxis_screen_resize(vaxis_screen *screen, vaxis_winsize size);
vaxis_window *vaxis_screen_window(vaxis_screen *screen);
vaxis_result vaxis_screen_read_cell(const vaxis_screen *screen, uint16_t col,
                                    uint16_t row, vaxis_cell *cell);

/* Windows are lightweight owned snapshots referring to a screen. */
void vaxis_window_free(vaxis_window *window);
vaxis_window *vaxis_window_child(const vaxis_window *parent,
                                 vaxis_window_options options);
uint16_t vaxis_window_width(const vaxis_window *window);
uint16_t vaxis_window_height(const vaxis_window *window);
void vaxis_window_clear(vaxis_window *window);
vaxis_result vaxis_window_fill(vaxis_window *window, const vaxis_cell *cell);
vaxis_result vaxis_window_write_cell(vaxis_window *window, uint16_t col,
                                     uint16_t row, const vaxis_cell *cell);
vaxis_result vaxis_window_read_cell(const vaxis_window *window, uint16_t col,
                                    uint16_t row, vaxis_cell *cell);
uint16_t vaxis_window_grapheme_width(const vaxis_window *window,
                                     const uint8_t *text, size_t len);
void vaxis_window_hide_cursor(vaxis_window *window);
void vaxis_window_show_cursor(vaxis_window *window, uint16_t col, uint16_t row);
void vaxis_window_set_cursor_shape(vaxis_window *window, uint8_t shape);
vaxis_result vaxis_window_print(vaxis_window *window,
                                const vaxis_segment *segments, size_t count,
                                vaxis_print_options options,
                                vaxis_print_result *result);
void vaxis_window_scroll(vaxis_window *window, uint16_t rows);

/* Capability state is an ABI value rather than an exposed Zig layout. */
vaxis_capabilities vaxis_capabilities_default(void);

/* TextInput owns its text. get_text is borrowed until the next mutating call
 * or free. update_key accepts only parser key events. */
vaxis_result vaxis_text_input_new(vaxis_text_input **input);
vaxis_result vaxis_text_input_new_with_allocator(
    const vaxis_allocator *allocator, vaxis_text_input **input);
void vaxis_text_input_free(vaxis_text_input *input);
vaxis_result vaxis_text_input_insert(vaxis_text_input *input,
                                     const uint8_t *text, size_t len);
vaxis_result vaxis_text_input_update_key(vaxis_text_input *input,
                                         const vaxis_event *event);
vaxis_result vaxis_text_input_get_text(vaxis_text_input *input,
                                       vaxis_string *text);
void vaxis_text_input_reset(vaxis_text_input *input);
void vaxis_text_input_cursor_left(vaxis_text_input *input);
void vaxis_text_input_cursor_right(vaxis_text_input *input);
vaxis_result vaxis_text_input_draw(vaxis_text_input *input,
                                   vaxis_window *window,
                                   const vaxis_style *style);

typedef enum VAXIS_ENUM_TYPED {
  VAXIS_TERMINAL_EVENT_NONE = 0, VAXIS_TERMINAL_EVENT_EXITED = 1,
  VAXIS_TERMINAL_EVENT_REDRAW = 2, VAXIS_TERMINAL_EVENT_BELL = 3,
  VAXIS_TERMINAL_EVENT_TITLE = 4, VAXIS_TERMINAL_EVENT_PWD = 5,
  VAXIS_TERMINAL_EVENT_MAX_VALUE = VAXIS_ENUM_MAX_VALUE,
} vaxis_terminal_event_type;
typedef struct { int32_t type; vaxis_string text; } vaxis_terminal_event;
typedef struct {
  uint16_t scrollback_size;
  vaxis_winsize size;
  vaxis_string working_directory; /* empty means inherit cwd */
  const vaxis_env_var *environment;
  size_t environment_count;
} vaxis_terminal_options;

/* Embedded terminal/PTY. argv and options are copied. The handle is confined
 * to its creating thread except for its internal reader worker. Event text is
 * borrowed until the next vaxis_terminal_try_event call. PTYs are currently
 * supported only on Linux; elsewhere new returns VAXIS_ERR_UNSUPPORTED. */
vaxis_result vaxis_terminal_new(const vaxis_string *argv, size_t argc,
                                const vaxis_terminal_options *options,
                                vaxis_terminal **terminal);
vaxis_result vaxis_terminal_new_with_allocator(
    const vaxis_allocator *allocator, const vaxis_string *argv, size_t argc,
    const vaxis_terminal_options *options, vaxis_terminal **terminal);
void vaxis_terminal_free(vaxis_terminal *terminal);
vaxis_result vaxis_terminal_spawn(vaxis_terminal *terminal);
vaxis_result vaxis_terminal_resize(vaxis_terminal *terminal, vaxis_winsize size);
vaxis_result vaxis_terminal_draw(vaxis_terminal *terminal, vaxis_window *window);
vaxis_result vaxis_terminal_update_key(vaxis_terminal *terminal,
                                       const vaxis_event *event);
vaxis_result vaxis_terminal_try_event(vaxis_terminal *terminal,
                                      vaxis_terminal_event *event,
                                      bool *available);

typedef enum VAXIS_ENUM_TYPED {
  VAXIS_IMAGE_SCALE_NONE = 0, VAXIS_IMAGE_SCALE_FILL = 1,
  VAXIS_IMAGE_SCALE_FIT = 2, VAXIS_IMAGE_SCALE_CONTAIN = 3,
  VAXIS_IMAGE_SCALE_MAX_VALUE = VAXIS_ENUM_MAX_VALUE,
} vaxis_image_scale;
typedef enum VAXIS_ENUM_TYPED {
  VAXIS_IMAGE_RGB = 0, VAXIS_IMAGE_RGBA = 1, VAXIS_IMAGE_PNG = 2,
  VAXIS_IMAGE_FORMAT_MAX_VALUE = VAXIS_ENUM_MAX_VALUE,
} vaxis_image_format;
typedef enum VAXIS_ENUM_TYPED {
  VAXIS_IMAGE_FILE = 0, VAXIS_IMAGE_TEMP_FILE = 1,
  VAXIS_IMAGE_SHARED_MEMORY = 2,
  VAXIS_IMAGE_MEDIUM_MAX_VALUE = VAXIS_ENUM_MAX_VALUE,
} vaxis_image_medium;
typedef struct { int32_t scale; int32_t z_index; bool has_z_index; } vaxis_image_draw_options;
/* An image value represents an already-transmitted Kitty image. Runtime
 * transmission functions assign the id; this constructor supports renderers
 * which perform transmission themselves. */
vaxis_result vaxis_image_new(uint32_t id, uint16_t pixel_width,
                             uint16_t pixel_height, vaxis_image **image);
vaxis_result vaxis_image_new_with_allocator(const vaxis_allocator *allocator,
                                            uint32_t id, uint16_t pixel_width,
                                            uint16_t pixel_height,
                                            vaxis_image **image);
void vaxis_image_free(vaxis_image *image);
uint32_t vaxis_image_id(const vaxis_image *image);
vaxis_result vaxis_image_draw(const vaxis_image *image, vaxis_window *window,
                              vaxis_image_draw_options options);
vaxis_result vaxis_image_cell_size(const vaxis_image *image,
                                   const vaxis_window *window,
                                   uint16_t *cols, uint16_t *rows);

/* TTY enters raw mode on creation and restores the original mode on free.
 * A runtime borrows its TTY, which must outlive the runtime and all windows. */
typedef struct {
  const vaxis_env_var *environment;
  size_t environment_count;
} vaxis_runtime_options;

vaxis_result vaxis_tty_new(vaxis_tty **tty);
vaxis_result vaxis_tty_new_with_allocator(const vaxis_allocator *allocator,
                                          vaxis_tty **tty);
void vaxis_tty_free(vaxis_tty *tty);
vaxis_result vaxis_tty_winsize(vaxis_tty *tty, vaxis_winsize *size);
vaxis_result vaxis_tty_read(vaxis_tty *tty, uint8_t *buffer,
                            size_t capacity, size_t *length);
/* Windows console input is record-based rather than a byte stream. On
 * Windows use this blocking call; on other platforms it returns
 * VAXIS_ERR_UNSUPPORTED and callers use tty_read + parser_parse. */
vaxis_result vaxis_tty_next_event(vaxis_tty *tty, vaxis_parser *parser,
                                  const vaxis_event **event);
vaxis_result vaxis_runtime_new(vaxis_tty *tty,
                               const vaxis_runtime_options *options,
                               vaxis_runtime **runtime);
vaxis_result vaxis_runtime_new_with_allocator(
    const vaxis_allocator *allocator, vaxis_tty *tty,
    const vaxis_runtime_options *options, vaxis_runtime **runtime);
void vaxis_runtime_free(vaxis_runtime *runtime);
vaxis_result vaxis_runtime_resize(vaxis_runtime *runtime, vaxis_winsize size);
vaxis_window *vaxis_runtime_window(vaxis_runtime *runtime);
vaxis_result vaxis_runtime_render(vaxis_runtime *runtime);
vaxis_result vaxis_runtime_enter_alt_screen(vaxis_runtime *runtime);
vaxis_result vaxis_runtime_exit_alt_screen(vaxis_runtime *runtime);
vaxis_result vaxis_runtime_query_terminal(vaxis_runtime *runtime,
                                          uint64_t timeout_ns);
/* For a custom event loop, call send, parse and handle all query responses,
 * then call finish to enable the detected terminal features. */
vaxis_result vaxis_runtime_query_terminal_send(vaxis_runtime *runtime);
vaxis_result vaxis_runtime_query_terminal_finish(vaxis_runtime *runtime);
/* Apply a parsed event to runtime state. Capability events are intercepted in
 * the same way as vaxis.Loop; other events are accepted without mutation. */
vaxis_result vaxis_runtime_handle_event(vaxis_runtime *runtime,
                                        const vaxis_event *event);
void vaxis_runtime_queue_refresh(vaxis_runtime *runtime);
vaxis_capabilities vaxis_runtime_capabilities(const vaxis_runtime *runtime);
vaxis_result vaxis_runtime_set_mouse_mode(vaxis_runtime *runtime, bool enabled);
vaxis_result vaxis_runtime_set_bracketed_paste(vaxis_runtime *runtime, bool enabled);
vaxis_result vaxis_runtime_set_title(vaxis_runtime *runtime,
                                     const uint8_t *title, size_t length);
vaxis_result vaxis_runtime_load_image_memory(vaxis_runtime *runtime,
                                             const uint8_t *data, size_t length,
                                             vaxis_image **image);
vaxis_result vaxis_runtime_transmit_image_path(vaxis_runtime *runtime,
                                               const uint8_t *path, size_t length,
                                               uint16_t width, uint16_t height,
                                               int32_t medium, int32_t format,
                                               vaxis_image **image);
vaxis_result vaxis_runtime_transmit_image_base64(vaxis_runtime *runtime,
                                                 const uint8_t *data, size_t length,
                                                 uint16_t width, uint16_t height,
                                                 int32_t format,
                                                 vaxis_image **image);
void vaxis_runtime_free_transmitted_image(vaxis_runtime *runtime,
                                          uint32_t image_id);

/* An opaque parsed event, owned by the parser that produced it and valid
 * until the next parse call. Read it through the accessors below. */
/* Create a parser. Returns NULL on allocation failure. */
vaxis_parser *vaxis_parser_new(void);
vaxis_parser *vaxis_parser_new_with_allocator(
    const vaxis_allocator *allocator);

/* Destroy a parser created with vaxis_parser_new, along with any event it
 * currently owns. NULL is a no-op. */
void vaxis_parser_free(vaxis_parser *parser);

/* Parse the first event from `input`. On success returns VAXIS_OK, stores
 * the bytes consumed in `consumed`, and stores an event handle in `event`,
 * or NULL when no event was produced:
 *
 * - *event == NULL, *consumed == 0: incomplete sequence; read more bytes
 *   and retry with the whole buffer. The caller owns accumulation and
 *   should cap the buffer.
 * - *event == NULL, *consumed > 0: an unknown, ignored, or malformed
 *   sequence; skip those bytes and continue.
 *
 * A lone ESC byte parses as an escape key press: wait briefly for more
 * input before parsing a buffer that ends in ESC.
 *
 * On error returns a VAXIS_ERR_* code and consumes nothing. */
vaxis_result vaxis_parser_parse(vaxis_parser *parser, const uint8_t *input,
                                size_t input_len, const vaxis_event **event,
                                size_t *consumed);

/* The type of an event. Accessors are NULL-safe: a NULL event has type
 * VAXIS_EVENT_NONE, and accessors return zero values when the event is
 * NULL or not of the matching type. */
vaxis_event_type vaxis_event_get_type(const vaxis_event *event);

/* Key accessors (VAXIS_EVENT_KEY_PRESS, VAXIS_EVENT_KEY_RELEASE). Key
 * text longer than 256 bytes is truncated at a codepoint boundary and is
 * always valid UTF-8. Shifted and base-layout codepoints are 0 when not
 * present. */
uint32_t vaxis_event_key_codepoint(const vaxis_event *event);
uint32_t vaxis_event_key_shifted_codepoint(const vaxis_event *event);
uint32_t vaxis_event_key_base_layout_codepoint(const vaxis_event *event);
uint8_t vaxis_event_key_mods(const vaxis_event *event);
vaxis_string vaxis_event_key_text(const vaxis_event *event);

/* Match a key event against a codepoint + modifiers, using the same loose
 * matching as the Zig library. Always false for non-key events. */
bool vaxis_event_key_matches(const vaxis_event *event, uint32_t codepoint,
                             uint8_t mods);

/* Mouse accessors (VAXIS_EVENT_MOUSE). col/row are 0-indexed and may be
 * negative for terminals that report out-of-window coordinates. */
int16_t vaxis_event_mouse_col(const vaxis_event *event);
int16_t vaxis_event_mouse_row(const vaxis_event *event);
uint8_t vaxis_event_mouse_button(const vaxis_event *event);
uint8_t vaxis_event_mouse_mods(const vaxis_event *event);
uint8_t vaxis_event_mouse_type(const vaxis_event *event);

/* Paste accessor (VAXIS_EVENT_PASTE). */
vaxis_string vaxis_event_paste_text(const vaxis_event *event);

/* Color report accessors (VAXIS_EVENT_COLOR_REPORT). `index` is only
 * meaningful when the kind is VAXIS_COLOR_INDEX. */
uint8_t vaxis_event_color_report_kind(const vaxis_event *event);
uint8_t vaxis_event_color_report_index(const vaxis_event *event);
vaxis_rgb vaxis_event_color_report_rgb(const vaxis_event *event);

/* Color scheme accessor (VAXIS_EVENT_COLOR_SCHEME); a
 * VAXIS_COLOR_SCHEME_* value. */
uint8_t vaxis_event_color_scheme(const vaxis_event *event);

/* Window size accessors (VAXIS_EVENT_WINSIZE). */
uint16_t vaxis_event_winsize_rows(const vaxis_event *event);
uint16_t vaxis_event_winsize_cols(const vaxis_event *event);
uint16_t vaxis_event_winsize_x_pixel(const vaxis_event *event);
uint16_t vaxis_event_winsize_y_pixel(const vaxis_event *event);

/* Look up a key codepoint by name ("enter", "f1", "kp_0", ...). Returns 0
 * for unknown names. */
uint32_t vaxis_key_from_name(const char *name, size_t name_len);

/* The libvaxis version as a static string, e.g. "0.6.0". */
const char *vaxis_version(void);

/* Key codepoints. Special keys use the Kitty keyboard protocol's private
 * use area assignments; a handful are plain ASCII. */
#define VAXIS_KEY_TAB 0x09
#define VAXIS_KEY_ENTER 0x0D
#define VAXIS_KEY_ESCAPE 0x1B
#define VAXIS_KEY_SPACE 0x20
#define VAXIS_KEY_BACKSPACE 0x7F

/* A key which generated text but cannot be expressed as a single
 * codepoint (e.g. a multi-codepoint grapheme). Inspect the key text
 * instead. */
#define VAXIS_KEY_MULTICODEPOINT 1114113

#define VAXIS_KEY_INSERT 57348
#define VAXIS_KEY_DELETE 57349
#define VAXIS_KEY_LEFT 57350
#define VAXIS_KEY_RIGHT 57351
#define VAXIS_KEY_UP 57352
#define VAXIS_KEY_DOWN 57353
#define VAXIS_KEY_PAGE_UP 57354
#define VAXIS_KEY_PAGE_DOWN 57355
#define VAXIS_KEY_HOME 57356
#define VAXIS_KEY_END 57357
#define VAXIS_KEY_CAPS_LOCK 57358
#define VAXIS_KEY_SCROLL_LOCK 57359
#define VAXIS_KEY_NUM_LOCK 57360
#define VAXIS_KEY_PRINT_SCREEN 57361
#define VAXIS_KEY_PAUSE 57362
#define VAXIS_KEY_MENU 57363
#define VAXIS_KEY_F1 57364
#define VAXIS_KEY_F2 57365
#define VAXIS_KEY_F3 57366
#define VAXIS_KEY_F4 57367
#define VAXIS_KEY_F5 57368
#define VAXIS_KEY_F6 57369
#define VAXIS_KEY_F7 57370
#define VAXIS_KEY_F8 57371
#define VAXIS_KEY_F9 57372
#define VAXIS_KEY_F10 57373
#define VAXIS_KEY_F11 57374
#define VAXIS_KEY_F12 57375
#define VAXIS_KEY_F13 57376
#define VAXIS_KEY_F14 57377
#define VAXIS_KEY_F15 57378
#define VAXIS_KEY_F16 57379
#define VAXIS_KEY_F17 57380
#define VAXIS_KEY_F18 57381
#define VAXIS_KEY_F19 57382
#define VAXIS_KEY_F20 57383
#define VAXIS_KEY_F21 57384
#define VAXIS_KEY_F22 57385
#define VAXIS_KEY_F23 57386
#define VAXIS_KEY_F24 57387
#define VAXIS_KEY_F25 57388
#define VAXIS_KEY_F26 57389
#define VAXIS_KEY_F27 57390
#define VAXIS_KEY_F28 57391
#define VAXIS_KEY_F29 57392
#define VAXIS_KEY_F30 57393
#define VAXIS_KEY_F31 57394
#define VAXIS_KEY_F32 57395
#define VAXIS_KEY_F33 57396
#define VAXIS_KEY_F34 57397
#define VAXIS_KEY_F35 57398
#define VAXIS_KEY_KP_0 57399
#define VAXIS_KEY_KP_1 57400
#define VAXIS_KEY_KP_2 57401
#define VAXIS_KEY_KP_3 57402
#define VAXIS_KEY_KP_4 57403
#define VAXIS_KEY_KP_5 57404
#define VAXIS_KEY_KP_6 57405
#define VAXIS_KEY_KP_7 57406
#define VAXIS_KEY_KP_8 57407
#define VAXIS_KEY_KP_9 57408
#define VAXIS_KEY_KP_DECIMAL 57409
#define VAXIS_KEY_KP_DIVIDE 57410
#define VAXIS_KEY_KP_MULTIPLY 57411
#define VAXIS_KEY_KP_SUBTRACT 57412
#define VAXIS_KEY_KP_ADD 57413
#define VAXIS_KEY_KP_ENTER 57414
#define VAXIS_KEY_KP_EQUAL 57415
#define VAXIS_KEY_KP_SEPARATOR 57416
#define VAXIS_KEY_KP_LEFT 57417
#define VAXIS_KEY_KP_RIGHT 57418
#define VAXIS_KEY_KP_UP 57419
#define VAXIS_KEY_KP_DOWN 57420
#define VAXIS_KEY_KP_PAGE_UP 57421
#define VAXIS_KEY_KP_PAGE_DOWN 57422
#define VAXIS_KEY_KP_HOME 57423
#define VAXIS_KEY_KP_END 57424
#define VAXIS_KEY_KP_INSERT 57425
#define VAXIS_KEY_KP_DELETE 57426
#define VAXIS_KEY_KP_BEGIN 57427
#define VAXIS_KEY_MEDIA_PLAY 57428
#define VAXIS_KEY_MEDIA_PAUSE 57429
#define VAXIS_KEY_MEDIA_PLAY_PAUSE 57430
#define VAXIS_KEY_MEDIA_REVERSE 57431
#define VAXIS_KEY_MEDIA_STOP 57432
#define VAXIS_KEY_MEDIA_FAST_FORWARD 57433
#define VAXIS_KEY_MEDIA_REWIND 57434
#define VAXIS_KEY_MEDIA_TRACK_NEXT 57435
#define VAXIS_KEY_MEDIA_TRACK_PREVIOUS 57436
#define VAXIS_KEY_MEDIA_RECORD 57437
#define VAXIS_KEY_LOWER_VOLUME 57438
#define VAXIS_KEY_RAISE_VOLUME 57439
#define VAXIS_KEY_MUTE_VOLUME 57440
#define VAXIS_KEY_LEFT_SHIFT 57441
#define VAXIS_KEY_LEFT_CONTROL 57442
#define VAXIS_KEY_LEFT_ALT 57443
#define VAXIS_KEY_LEFT_SUPER 57444
#define VAXIS_KEY_LEFT_HYPER 57445
#define VAXIS_KEY_LEFT_META 57446
#define VAXIS_KEY_RIGHT_SHIFT 57447
#define VAXIS_KEY_RIGHT_CONTROL 57448
#define VAXIS_KEY_RIGHT_ALT 57449
#define VAXIS_KEY_RIGHT_SUPER 57450
#define VAXIS_KEY_RIGHT_HYPER 57451
#define VAXIS_KEY_RIGHT_META 57452
#define VAXIS_KEY_ISO_LEVEL_3_SHIFT 57453
#define VAXIS_KEY_ISO_LEVEL_5_SHIFT 57454

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* VAXIS_H */
