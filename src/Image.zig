const std = @import("std");
const fmt = std.fmt;
const math = std.math;
const base64 = std.base64.standard.Encoder;
const zigimg = @import("zigimg");

const Window = @import("Window.zig");

const Image = @This();

const transmit_opener = "\x1b_Gf=32,i={d},s={d},v={d},m={d};";

pub const Source = union(enum) {
    path: []const u8,
    mem: []const u8,
};

pub const TransmitFormat = enum {
    rgb,
    rgba,
    png,
};

pub const TransmitMedium = enum {
    file,
    temp_file,
    shared_mem,
};

pub const Placement = struct {
    img_id: u32,
    options: Image.DrawOptions,
};

pub const CellSize = struct {
    rows: u16,
    cols: u16,
};

pub const DrawOptions = struct {
    /// an offset into the top left cell, in pixels, with where to place the
    /// origin of the image. These must be less than the pixel size of a single
    /// cell
    pixel_offset: ?struct {
        x: u16,
        y: u16,
    } = null,
    /// the vertical stacking order
    /// < 0: Drawn beneath text
    /// < -1_073_741_824: Drawn beneath "default" background cells
    z_index: ?i32 = null,
    /// A clip region of the source image to draw.
    clip_region: ?struct {
        x: ?u16 = null,
        y: ?u16 = null,
        width: ?u16 = null,
        height: ?u16 = null,
    } = null,
    /// Scaling to apply to the Image
    scale: enum {
        /// no scaling applied. the image may extend beyond the window
        none,
        /// Stretch / shrink the image to fill the window
        fill,
        /// Scale the image to fit the window, maintaining aspect ratio
        fit,
        /// Scale the image to fit the window, only if needed.
        contain,
    } = .none,
    /// the size to render the image. Generally you will not need to use this
    /// field, and should prefer to use scale. `draw` will fill in this field with
    /// the correct values if a scale method is applied.
    size: ?struct {
        rows: ?u16 = null,
        cols: ?u16 = null,
    } = null,
};

/// unique identifier for this image. This will be managed by the screen.
id: u32,

/// width in pixels
width: u16,
/// height in pixels
height: u16,

pub fn draw(self: Image, win: Window, opts: DrawOptions) !void {
    var p_opts = opts;
    switch (opts.scale) {
        .none => {},
        .fill => {
            p_opts.size = .{
                .rows = win.height,
                .cols = win.width,
            };
        },
        .fit,
        .contain,
        => contain: {
            // cell geometry
            const x_pix = win.screen.width_pix;
            const y_pix = win.screen.height_pix;
            const w = win.screen.width;
            const h = win.screen.height;

            const pix_per_col = try std.math.divCeil(usize, x_pix, w);
            const pix_per_row = try std.math.divCeil(usize, y_pix, h);

            const win_width_pix = pix_per_col * win.width;
            const win_height_pix = pix_per_row * win.height;

            const fit_x: bool = if (win_width_pix >= self.width) true else false;
            const fit_y: bool = if (win_height_pix >= self.height) true else false;

            // Does the image fit with no scaling?
            if (opts.scale == .contain and fit_x and fit_y) break :contain;

            // Does the image require vertical scaling?
            if (fit_x and !fit_y)
                p_opts.size = .{
                    .rows = win.height,
                }

                    // Does the image require horizontal scaling?
            else if (!fit_x and fit_y)
                p_opts.size = .{
                    .cols = win.width,
                }
            else if (!fit_x and !fit_y) {
                const diff_x = self.width - win_width_pix;
                const diff_y = self.height - win_height_pix;
                // The width difference is larger than the height difference.
                // Scale by width
                if (diff_x > diff_y)
                    p_opts.size = .{
                        .cols = win.width,
                    }
                else
                    // The height difference is larger than the width difference.
                    // Scale by height
                    p_opts.size = .{
                        .rows = win.height,
                    };
            } else {
                std.debug.assert(opts.scale == .fit);
                std.debug.assert(win_width_pix >= self.width);
                std.debug.assert(win_height_pix >= self.height);

                // Fits in both directions. Find the closer direction
                const diff_x = win_width_pix - self.width;
                const diff_y = win_height_pix - self.height;
                // The width is closer in dimension. Scale by that
                if (diff_x < diff_y)
                    p_opts.size = .{
                        .cols = win.width,
                    }
                else
                    p_opts.size = .{
                        .rows = win.height,
                    };
            }
        },
    }
    const p = Placement{
        .img_id = self.id,
        .options = p_opts,
    };
    win.writeCell(0, 0, .{ .image = p });
}

/// the size of the image, in cells
pub fn cellSize(self: Image, win: Window) !CellSize {
    // cell geometry
    const x_pix = win.screen.width_pix;
    const y_pix = win.screen.height_pix;
    const w = win.screen.width;
    const h = win.screen.height;

    const pix_per_col = try std.math.divCeil(u16, x_pix, w);
    const pix_per_row = try std.math.divCeil(u16, y_pix, h);

    const cell_width = std.math.divCeil(u16, self.width, pix_per_col) catch 0;
    const cell_height = std.math.divCeil(u16, self.height, pix_per_row) catch 0;
    return .{
        .rows = cell_height,
        .cols = cell_width,
    };
}
