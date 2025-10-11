# Migration Plan: zg → uucode

## Overview

This document outlines the plan to migrate from the `zg` dependency to `uucode` for grapheme segmentation and display width measurement in libvaxis.

## Key Advantage

**No allocation required** - uucode uses compile-time lookup tables instead of runtime-allocated data structures, eliminating the need to initialize, pass around, and deinitialize Unicode data.

## Current zg Usage

### Dependencies (from build.zig)
- `code_point` - UTF-8 codepoint iteration
- `Graphemes` - Grapheme cluster segmentation
- `DisplayWidth` - Display width calculation

### Files Using zg
- `src/main.zig` - Re-exports `Graphemes` and `DisplayWidth`
- `src/Unicode.zig` - Wrapper around zg data (allocates)
- `src/gwidth.zig` - Width calculation using `DisplayWidth`
- `src/Parser.zig` - Uses `code_point` and `Graphemes`
- `src/Loop.zig` - Uses `Graphemes`
- `src/widgets/TextView.zig` - Uses `Graphemes` and `DisplayWidth`
- `src/widgets/terminal/Terminal.zig` - Uses `code_point` and `DisplayWidth`

### Allocation Pattern (zg)
```zig
// Initialize with allocator
const graphemes = try Graphemes.init(alloc);
defer graphemes.deinit(alloc);

const width_data = try DisplayWidth.init(alloc);
defer width_data.deinit(alloc);

// Use
var iter = graphemes.iterator(str);
const width = width_data.codePointWidth(cp);
```

## uucode API

### Available Modules
- `uucode.utf8.Iterator` - UTF-8 codepoint iteration (no allocation)
- `uucode.grapheme.Iterator` - Grapheme cluster iteration (no allocation)
- `uucode.get()` - Compile-time Unicode property lookup (no allocation)

### Usage Pattern (uucode)
```zig
// UTF-8 iteration
var cp_iter = uucode.utf8.Iterator.init(str);
while (cp_iter.next()) |cp| {
    // process codepoint
}

// Grapheme iteration
var grapheme_iter = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(str));
while (grapheme_iter.next()) |result| {
    // result.cp is the codepoint
    // result.is_break indicates grapheme boundary
}

// Width lookup (requires wcwidth field in build config)
const width = uucode.get(.wcwidth, cp);

// Grapheme width (from uucode.x extension)
const g_width = uucode.x.grapheme.unverifiedWcwidth(grapheme_iter);
```

### Iterator Result Structure
```zig
pub const IteratorResult = struct {
    cp: u21,        // The codepoint
    is_break: bool, // true if this is a grapheme cluster boundary
};
```

## Migration Steps

### 1. Update build.zig.zon

Add `wcwidth` field to uucode dependency configuration:

```zig
.uucode = .{
    .url = "git+https://github.com/jacobsandlund/uucode#5f05f8f83a75caea201f12cc8ea32a2d82ea9732",
    .hash = "uucode-0.1.0-ZZjBPj96QADXyt5sqwBJUnhaDYs_qBeeKijZvlRa0eqM",
},
```

### 2. Update build.zig

In the uucode dependency configuration, update the fields array:

```zig
const uucode_dep = b.dependency("uucode", .{
    .target = target,
    .optimize = optimize,
    .fields = @as([]const []const u8, &.{
        "grapheme_break",
        "wcwidth", // ADD THIS
    }),
});
```

Remove zg dependency:
- Delete the `zg_dep` declaration
- Remove all `zg_dep.module()` references
- Remove `.zg` from build.zig.zon

### 3. Update Module Imports in build.zig

Replace:
```zig
vaxis_mod.addImport("code_point", zg_dep.module("code_point"));
vaxis_mod.addImport("Graphemes", zg_dep.module("Graphemes"));
vaxis_mod.addImport("DisplayWidth", zg_dep.module("DisplayWidth"));
```

No replacement needed - uucode is already imported.

### 4. Update src/main.zig

Remove:
```zig
pub const DisplayWidth = @import("DisplayWidth");
pub const Graphemes = @import("Graphemes");
```

These become internal implementation details or are removed entirely.

### 5. Update src/Unicode.zig

**Before:**
```zig
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");

const Unicode = @This();

width_data: DisplayWidth,

pub fn init(alloc: std.mem.Allocator) !Unicode {
    return .{
        .width_data = try DisplayWidth.init(alloc),
    };
}

pub fn deinit(self: *const Unicode, alloc: std.mem.Allocator) void {
    self.width_data.deinit(alloc);
}

pub fn graphemeIterator(self: *const Unicode, str: []const u8) Graphemes.Iterator {
    return self.width_data.graphemes.iterator(str);
}
```

**After:**
```zig
const uucode = @import("uucode");

const Unicode = @This();

// No fields needed - all operations are stateless

pub fn init(alloc: std.mem.Allocator) !Unicode {
    _ = alloc;
    return .{};
}

pub fn deinit(self: *const Unicode, alloc: std.mem.Allocator) void {
    _ = self;
    _ = alloc;
}

pub fn graphemeIterator(self: *const Unicode, str: []const u8) uucode.grapheme.Iterator(uucode.utf8.Iterator) {
    _ = self;
    return uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(str));
}
```

Or consider removing the `Unicode` wrapper entirely since it no longer serves a purpose.

### 6. Update src/gwidth.zig

**Before:**
```zig
const DisplayWidth = @import("DisplayWidth");
const code_point = @import("code_point");

pub fn gwidth(str: []const u8, method: Method, data: *const DisplayWidth) u16 {
    switch (method) {
        .unicode => {
            return @intCast(data.strWidth(str));
        },
        .wcwidth => {
            var total: u16 = 0;
            var iter: code_point.Iterator = .{ .bytes = str };
            while (iter.next()) |cp| {
                const w: u16 = switch (cp.code) {
                    0x1f3fb...0x1f3ff => 2,
                    else => @max(0, data.codePointWidth(cp.code)),
                };
                total += w;
            }
            return total;
        },
        // ...
    }
}
```

**After:**
```zig
const uucode = @import("uucode");

pub fn gwidth(str: []const u8, method: Method) u16 {
    switch (method) {
        .unicode => {
            var total: u16 = 0;
            var grapheme_iter = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(str));
            while (grapheme_iter.next()) |result| {
                if (result.is_break) {
                    // Calculate width for previous grapheme
                    // This requires buffering the grapheme - may need different approach
                }
            }
            return total;
        },
        .wcwidth => {
            var total: u16 = 0;
            var iter = uucode.utf8.Iterator.init(str);
            while (iter.next()) |cp| {
                const w: u16 = switch (cp) {
                    0x1f3fb...0x1f3ff => 2,
                    else => @max(0, uucode.get(.wcwidth, cp)),
                };
                total += w;
            }
            return total;
        },
        // ...
    }
}
```

Note: Remove the `data` parameter entirely.

### 7. Update src/Parser.zig

Replace:
```zig
const code_point = @import("code_point");
const Graphemes = @import("Graphemes");
```

With:
```zig
const uucode = @import("uucode");
```

Replace:
```zig
grapheme_data: *const Graphemes,
```

With:
```zig
// Remove this field entirely if only used for iteration
```

Replace usage:
```zig
var iter: code_point.Iterator = .{ .bytes = input };
```

With:
```zig
var iter = uucode.utf8.Iterator.init(input);
```

### 8. Update Other Files

Apply similar transformations to:
- `src/Loop.zig`
- `src/widgets/TextView.zig`
- `src/widgets/terminal/Terminal.zig`

Pattern:
1. Replace imports with `const uucode = @import("uucode");`
2. Remove allocated data fields
3. Replace `code_point.Iterator` with `uucode.utf8.Iterator`
4. Replace `graphemes.iterator()` with `uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(str))`
5. Replace `data.codePointWidth(cp)` with `uucode.get(.wcwidth, cp)`

### 9. Update Tests

All test code that does:
```zig
const data = try DisplayWidth.init(alloc);
defer data.deinit(alloc);
```

Can be removed entirely. Width lookups become:
```zig
const width = uucode.get(.wcwidth, cp);
```

## API Mapping Reference

| zg API | uucode API |
|--------|------------|
| `code_point.Iterator{ .bytes = str }` | `uucode.utf8.Iterator.init(str)` |
| `iter.next().code` | `iter.next()` (returns u21 directly) |
| `Graphemes.init(alloc)` | _(no initialization needed)_ |
| `graphemes.iterator(str)` | `uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(str))` |
| `DisplayWidth.init(alloc)` | _(no initialization needed)_ |
| `width_data.codePointWidth(cp)` | `uucode.get(.wcwidth, cp)` |
| `width_data.strWidth(str)` | _(implement using iterator + uucode.get)_ |

## Benefits

1. **No allocations** - All Unicode data is compile-time generated
2. **Simpler API** - No init/deinit lifecycle
3. **Less state to manage** - No data structures to pass around
4. **Smaller binary** - Only requested fields are included
5. **Type-safe lookups** - Field names are compile-time checked

## Potential Challenges

1. **String width calculation** - zg's `strWidth()` is convenient; need to implement equivalent using iterator
2. **Grapheme-aware width** - May need `uucode.x.grapheme.unverifiedWcwidth()` for proper emoji/ZWJ handling
3. **Iterator API differences** - zg returns struct with `.code`, uucode returns `u21` directly
4. **Breaking API changes** - Any public APIs exposing `Graphemes` or `DisplayWidth` types will need updates

## Testing Strategy

1. Run existing tests with uucode implementation
2. Pay special attention to:
   - Emoji with ZWJ sequences
   - Skin tone modifiers
   - Variation selectors
   - Complex grapheme clusters
3. Compare width calculations with zg implementation
4. Test memory usage (should be lower without allocations)

## Rollback Plan

If issues arise, the zg dependency can be re-added to build.zig.zon and the imports restored. The changes are isolated to a small number of files.
