const c = @cImport({
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("xcb/xcb.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xlib-xcb.h");
    @cInclude("pango/pangocairo.h");
    @cInclude("cairo/cairo-xcb.h");
});

const std = @import("std");

const Term = @import("Term.zig");

const heap = std.heap;
const io = std.io;
const math = std.math;
const mem = std.mem;

pub fn main() anyerror!void {
    var arena_state = heap.ArenaAllocator.init(heap.page_allocator);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    var out = std.ArrayList(u8).init(arena);
    defer out.deinit();

    var term = try Term.init(arena, .{
        .{ .r = 0x14, .g = 0x14, .b = 0x14 },
        .{ .r = 0xf0, .g = 0x32, .b = 0x32 },
        .{ .r = 0x78, .g = 0xb4, .b = 0x96 },
        .{ .r = 0xc8, .g = 0x82, .b = 0x1e },
        .{ .r = 0x3c, .g = 0x78, .b = 0xe6 },
        .{ .r = 0x64, .g = 0x64, .b = 0xe6 },
        .{ .r = 0x3c, .g = 0x96, .b = 0xb4 },
        .{ .r = 0xdc, .g = 0xdc, .b = 0xdc },
        .{ .r = 0x50, .g = 0x50, .b = 0x50 },
        .{ .r = 0xf0, .g = 0x32, .b = 0x32 },
        .{ .r = 0x78, .g = 0xb4, .b = 0x96 },
        .{ .r = 0xc8, .g = 0x82, .b = 0x1e },
        .{ .r = 0x3c, .g = 0x78, .b = 0xe6 },
        .{ .r = 0x64, .g = 0x64, .b = 0xe6 },
        .{ .r = 0x3c, .g = 0x96, .b = 0xb4 },
        .{ .r = 0xdc, .g = 0xdc, .b = 0xdc },
    });

    var window = try Window.create();
    defer window.close();

    var master: c_int = undefined;
    var slave: c_int = undefined;
    _ = c.openpty(&master, &slave, null, null, null);

    const pid = try std.os.fork();
    switch (pid) {
        0 => {
            std.os.close(master);
            _ = c.setsid();
            try std.os.dup2(slave, 0);
            try std.os.dup2(slave, 1);
            try std.os.dup2(slave, 2);
            _ = c.ioctl(slave, c.TIOCSCTTY, @as(?*anyopaque, null));
            std.os.close(slave);

            const sh = "/bin/sh";
            const logname = "hejsil";
            const user = logname;
            const home = "/home/hejsil";
            const term_env = "st-256color";

            _ = c.unsetenv("COLUMNS");
            _ = c.unsetenv("LINES");
            _ = c.unsetenv("TERMCAP");
            _ = c.setenv("LOGNAME", logname, 1);
            _ = c.setenv("USER", user, 1);
            _ = c.setenv("SHELL", sh, 1);
            _ = c.setenv("HOME", home, 1);
            _ = c.setenv("TERM", term_env, 1);
            _ = c.execvp(sh, &[_:null][*c]u8{null});
            return;
        },
        else => {
            std.os.close(slave);
        },
    }

    const xfd = c.xcb_get_file_descriptor(window.conn);
    const ttyfd = master;
    _ = ttyfd;

    const epfd = try std.os.epoll_create1(0);
    var x_event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN,
        .data = .{ .fd = xfd },
    };
    try std.os.epoll_ctl(epfd, std.os.linux.EPOLL.CTL_ADD, xfd, &x_event);

    var tty_event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN,
        .data = .{ .fd = ttyfd },
    };
    try std.os.epoll_ctl(epfd, std.os.linux.EPOLL.CTL_ADD, ttyfd, &tty_event);

    while (true) {
        var event_buf: [1]std.os.linux.epoll_event = undefined;
        const event_len = std.os.epoll_wait(epfd, &event_buf, -1);
        std.debug.assert(event_len == 1);

        var redraw = false;
        if (event_buf[0].data.fd == ttyfd) {
            var buf: [1024]u8 = undefined;
            const l = try std.os.read(ttyfd, &buf);
            std.log.info("{}", .{std.zig.fmtEscapes(buf[0..l])});

            const view = try std.unicode.Utf8View.init(buf[0..l]);
            var it = view.iterator();
            while (it.nextCodepoint()) |cp|
                try term.feed(cp);

            redraw = true;
        }

        while (c.XPending(window.display) != 0) {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(window.display, &event);
            if (c.XFilterEvent(&event, c.None) != 0)
                continue;

            switch (event.type) {
                c.Expose => {
                    redraw = true;
                },
                c.KeyPress => {
                    const key = &event.xkey;

                    var keysym: c.KeySym = undefined;
                    var buf: [mem.page_size]u8 = undefined;
                    const len = c.XLookupString(key, &buf, buf.len, &keysym, null);
                    _ = try std.os.write(ttyfd, buf[0..@intCast(usize, len)]);
                    std.log.info("Press: {} {}", .{ keysym, std.fmt.fmtSliceHexLower(buf[0..@intCast(usize, len)]) });

                    switch (keysym) {
                        // c.XK_BackSpace => _ = try std.os.write(ttyfd, "\x7f"),
                        c.XK_KP_Enter => _ = try std.os.write(ttyfd, "\n"),
                        c.XK_Left => _ = try std.os.write(ttyfd, "\x1b[D"),
                        c.XK_Up => _ = try std.os.write(ttyfd, "\x1b[A"),
                        c.XK_Right => _ = try std.os.write(ttyfd, "\x1b[C"),
                        c.XK_Down => _ = try std.os.write(ttyfd, "\x1b[B"),
                        else => {},
                    }
                },
                c.ConfigureNotify => {
                    const config = &event.xconfigure;
                    if (window.width == config.width and window.height == config.height)
                        continue;

                    window.width = @intCast(u16, config.width);
                    window.height = @intCast(u16, config.height);

                    c.cairo_xcb_surface_set_size(window.surface, window.width, window.height);
                    c.pango_layout_set_width(window.layout, window.width * c.PANGO_SCALE);
                },
                else => {},
            }
        }

        if (redraw) {
            const attrs = c.pango_attr_list_new();
            defer c.pango_attr_list_unref(attrs);
            defer out.shrinkRetainingCapacity(0);

            const attr_hp = c.pango_attr_insert_hyphens_new(c.FALSE);
            attr_hp.*.start_index = 0;
            attr_hp.*.end_index = 0xffffff;
            c.pango_attr_list_insert(attrs, attr_hp);

            const term_screen = term.screen();
            std.log.info("Huh {}", .{term_screen.currentLine().glyphs.items.len});

            // Render the first glyph outside the loop so we can setup the first attributes.
            var it = term_screen.renderIterator(term.reset_attr, term.cursor_attr);
            const first = it.next().?;
            try out.writer().print("{u}", .{first.cp});

            var curr = first.attr;
            var curr_fg = c.pango_attr_foreground_new(
                @as(u16, curr.fg.r) * 257,
                @as(u16, curr.fg.g) * 257,
                @as(u16, curr.fg.b) * 257,
            );
            curr_fg.*.start_index = 0;

            var curr_bg = c.pango_attr_background_new(
                @as(u16, curr.bg.r) * 257,
                @as(u16, curr.bg.g) * 257,
                @as(u16, curr.bg.b) * 257,
            );
            curr_bg.*.start_index = 0;

            var curr_weight = c.pango_attr_weight_new(
                if (curr.bold) c.PANGO_WEIGHT_BOLD else c.PANGO_WEIGHT_NORMAL,
            );
            curr_weight.*.start_index = 0;

            while (it.next()) |glyph| {
                const start = out.items.len;
                try out.writer().print("{u}", .{glyph.cp});

                if (!std.meta.eql(curr.fg, glyph.attr.fg)) {
                    curr_fg.*.end_index = @intCast(c_uint, start);
                    c.pango_attr_list_insert(attrs, curr_fg);

                    curr_fg = c.pango_attr_foreground_new(
                        @as(u16, glyph.attr.fg.r) * 257,
                        @as(u16, glyph.attr.fg.g) * 257,
                        @as(u16, glyph.attr.fg.b) * 257,
                    );
                    curr_fg.*.start_index = @intCast(c_uint, start);
                }
                if (!std.meta.eql(curr.bg, glyph.attr.bg)) {
                    curr_bg.*.end_index = @intCast(c_uint, start);
                    c.pango_attr_list_insert(attrs, curr_bg);

                    curr_bg = c.pango_attr_background_new(
                        @as(u16, glyph.attr.bg.r) * 257,
                        @as(u16, glyph.attr.bg.g) * 257,
                        @as(u16, glyph.attr.bg.b) * 257,
                    );
                    curr_bg.*.start_index = @intCast(c_uint, start);
                }
                if (curr.bold != glyph.attr.bold) {
                    curr_weight.*.end_index = @intCast(c_uint, start);
                    c.pango_attr_list_insert(attrs, curr_weight);

                    curr_weight = c.pango_attr_weight_new(
                        if (glyph.attr.bold) c.PANGO_WEIGHT_BOLD else c.PANGO_WEIGHT_NORMAL,
                    );
                    curr_weight.*.start_index = @intCast(c_uint, start);
                }

                curr = glyph.attr;
            }

            curr_fg.*.end_index = math.maxInt(c_uint);
            c.pango_attr_list_insert(attrs, curr_fg);
            curr_bg.*.end_index = math.maxInt(c_uint);
            c.pango_attr_list_insert(attrs, curr_bg);
            curr_weight.*.end_index = math.maxInt(c_uint);
            c.pango_attr_list_insert(attrs, curr_weight);

            c.pango_layout_set_text(window.layout, out.items.ptr, @intCast(c_int, out.items.len));
            c.pango_layout_set_attributes(window.layout, attrs);

            var ink: c.PangoRectangle = undefined;
            var log: c.PangoRectangle = undefined;
            c.pango_layout_get_pixel_extents(window.layout, &ink, &log);

            const diff = @intCast(usize, log.height) -| window.height;
            c.cairo_move_to(window.cairo, 0, -@intToFloat(f64, diff));
            c.cairo_set_source_rgb(
                window.cairo,
                @intToFloat(f64, term.colors[0].r) / 255,
                @intToFloat(f64, term.colors[0].g) / 255,
                @intToFloat(f64, term.colors[0].b) / 255,
            );

            c.cairo_paint(window.cairo);
            c.pango_cairo_update_layout(window.cairo, window.layout);
            c.pango_cairo_show_layout(window.cairo, window.layout);

            c.cairo_surface_flush(window.surface);
            _ = c.xcb_flush(window.conn);
        }
    }
}

const Window = struct {
    width: u16,
    height: u16,
    display: *c.Display,
    conn: *c.xcb_connection_t,
    surface: *c.cairo_surface_t,
    cairo: *c.cairo_t,
    layout: *c.PangoLayout,
    font_desc: *c.PangoFontDescription,

    fn create() !Window {
        const width: u16 = 800;
        const height: u16 = 600;

        const screen_index: c_int = 0;
        const display = c.XOpenDisplay(null).?;
        errdefer _ = c.XCloseDisplay(display);

        const conn = c.XGetXCBConnection(display).?;
        const screen = blk: {
            const setup = c.xcb_get_setup(conn);
            var iter = c.xcb_setup_roots_iterator(setup);
            var i: c_int = 0;
            while (iter.rem != 0) : (c.xcb_screen_next(&iter)) {
                if (i == screen_index)
                    break;
                i += 1;
            }

            break :blk &iter.data[0];
        };

        const win = c.xcb_generate_id(conn);
        _ = c.xcb_create_window(
            conn,
            c.XCB_COPY_FROM_PARENT,
            win,
            screen.root,
            0,
            0,
            width,
            height,
            5,
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            screen.root_visual,
            c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK,
            &[_]u32{
                screen.black_pixel,
                c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
                    c.XCB_EVENT_MASK_KEY_PRESS,
            },
        );
        _ = c.xcb_map_window(conn, win);

        const visual = blk: {
            var depth_iter = c.xcb_screen_allowed_depths_iterator(screen);
            while (depth_iter.rem != 0) : (c.xcb_depth_next(&depth_iter)) {
                var visual_iter = c.xcb_depth_visuals_iterator(depth_iter.data);
                while (visual_iter.rem != 0) : (c.xcb_visualtype_next(&visual_iter)) {
                    if (screen.root_visual == visual_iter.data.*.visual_id)
                        break :blk visual_iter.data;
                }
            }

            return error.NoVisual;
        };

        const surface = c.cairo_xcb_surface_create(conn, win, visual, width, height).?;
        errdefer c.cairo_surface_destroy(surface);

        const cairo = c.cairo_create(surface).?;
        errdefer c.cairo_destroy(cairo);

        const layout = c.pango_cairo_create_layout(cairo).?;
        errdefer c.g_object_unref(layout);

        const font_desc = c.pango_font_description_from_string("monospace").?;
        errdefer c.pango_font_description_free(font_desc);

        c.pango_layout_set_font_description(layout, font_desc);
        c.pango_layout_set_width(layout, width * c.PANGO_SCALE);
        c.pango_layout_set_wrap(layout, c.PANGO_WRAP_CHAR);
        _ = c.xcb_flush(conn);

        return Window{
            .width = width,
            .height = height,
            .display = display,
            .conn = conn,
            .surface = surface,
            .cairo = cairo,
            .layout = layout,
            .font_desc = font_desc,
        };
    }

    fn close(win: Window) void {
        c.pango_font_description_free(win.font_desc);
        c.g_object_unref(win.layout);
        c.cairo_destroy(win.cairo);
        c.cairo_surface_destroy(win.surface);
        c.pango_font_description_free(win.font_desc);
        _ = c.XCloseDisplay(win.display);
    }
};
