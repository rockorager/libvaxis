#include <vaxis.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>

typedef struct { size_t allocations, frees; } alloc_state;
static void *test_alloc(void *ctx, size_t len, uint8_t alignment,
                        uintptr_t return_address) {
  (void)alignment; (void)return_address;
  ((alloc_state *)ctx)->allocations++;
  return malloc(len);
}
static bool test_resize(void *ctx, void *memory, size_t memory_len,
                        uint8_t alignment, size_t new_len,
                        uintptr_t return_address) {
  (void)ctx; (void)memory; (void)memory_len; (void)alignment;
  (void)new_len; (void)return_address;
  return false;
}
static void *test_remap(void *ctx, void *memory, size_t memory_len,
                        uint8_t alignment, size_t new_len,
                        uintptr_t return_address) {
  (void)ctx; (void)memory_len; (void)alignment; (void)return_address;
  return realloc(memory, new_len);
}
static void test_free(void *ctx, void *memory, size_t memory_len,
                      uint8_t alignment, uintptr_t return_address) {
  (void)memory_len; (void)alignment; (void)return_address;
  ((alloc_state *)ctx)->frees++;
  free(memory);
}

static vaxis_color def(void) {
  vaxis_color c = { VAXIS_COLOR_DEFAULT, 0, 0, 0, 0 };
  return c;
}

int main(void) {
  alloc_state state = {0, 0};
  const vaxis_allocator_vtable allocator_vtable = {
      test_alloc, test_resize, test_remap, test_free};
  const vaxis_allocator allocator = {&state, &allocator_vtable};
  uint8_t *bytes = vaxis_alloc(&allocator, 32);
  assert(bytes);
  vaxis_free(&allocator, bytes, 32);

  vaxis_screen *screen = NULL;
  assert(vaxis_screen_new((vaxis_winsize){2, 8, 80, 160}, NULL) ==
         VAXIS_ERR_INVALID);
  assert(vaxis_screen_new_with_allocator(
      &allocator, (vaxis_winsize){2, 8, 80, 160}, &screen) == VAXIS_OK);
  vaxis_window *root = vaxis_screen_window(screen);
  assert(root && vaxis_window_width(root) == 8 && vaxis_window_height(root) == 2);

  vaxis_style style = {def(), def(), def(), 0, 1};
  vaxis_segment segment = {{(const uint8_t *)"hello", 5}, style};
  vaxis_print_result printed;
  assert(vaxis_window_print(root, &segment, 1,
                            (vaxis_print_options){0, 0, VAXIS_WRAP_GRAPHEME, true},
                            &printed) == VAXIS_OK);
  vaxis_cell cell;
  assert(vaxis_window_read_cell(root, 0, 0, &cell) == VAXIS_OK);
  assert(cell.grapheme.len == 1 && cell.grapheme.ptr[0] == 'h');

  /* Input bytes are copied, and repeated overwrites exercise bounded string
   * compaction rather than retaining every historical value. */
  uint8_t changing[] = "a";
  vaxis_cell changing_cell = {{changing, 1}, 1, style};
  assert(vaxis_window_write_cell(root, 7, 1, &changing_cell) == VAXIS_OK);
  changing[0] = 'z';
  assert(vaxis_window_read_cell(root, 7, 1, &cell) == VAXIS_OK);
  assert(cell.grapheme.ptr[0] == 'a');
  for (size_t i = 0; i < 70000; ++i) {
    changing[0] = (uint8_t)('a' + (i % 26));
    assert(vaxis_window_write_cell(root, 7, 1, &changing_cell) == VAXIS_OK);
  }

  vaxis_window *child = vaxis_window_child(root,
      (vaxis_window_options){1, 0, 6, 2, 15, style});
  assert(child);
  vaxis_window_hide_cursor(child);
  vaxis_window_show_cursor(child, 0, 0);

  vaxis_text_input *input = NULL;
  assert(vaxis_text_input_new(&input) == VAXIS_OK);
  assert(vaxis_text_input_insert(input, (const uint8_t *)"vaxis", 5) == VAXIS_OK);
  vaxis_string text;
  assert(vaxis_text_input_get_text(input, &text) == VAXIS_OK);
  assert(text.len == 5 && memcmp(text.ptr, "vaxis", 5) == 0);
  assert(vaxis_text_input_draw(input, child, &style) == VAXIS_OK);

  vaxis_image *image = NULL;
  assert(vaxis_image_new(7, 40, 40, &image) == VAXIS_OK);
  assert(vaxis_image_id(image) == 7);
  uint16_t image_cols, image_rows;
  assert(vaxis_image_cell_size(image, root, &image_cols, &image_rows) == VAXIS_OK);
  assert(vaxis_image_draw(image, root,
      (vaxis_image_draw_options){VAXIS_IMAGE_SCALE_CONTAIN, 0, false}) == VAXIS_OK);
  vaxis_image_free(image);

  vaxis_text_input_free(input);
  vaxis_window_free(child);
  vaxis_window_free(root);
  vaxis_screen_free(screen);
  assert(state.allocations == state.frees);
  return 0;
}
