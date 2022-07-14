const std = @import("std");

const debug = std.debug;
const math = std.math;
const mem = std.mem;

const Term = @This();

pub const Screen = @import("Screen.zig");

allocator: mem.Allocator,
primary_screen: Screen = Screen{},
alternate_screen: Screen = Screen{},
flags: Flags = Flags{},
colors: [16]Screen.Color,

// State used to parse escapes
params: std.ArrayListUnmanaged(usize) = std.ArrayListUnmanaged(usize){},
state: enum {
    escape_start,
    escape,
    csi_params_first,
    csi_params_next,
    csi_params,
    csi_inter,
    normal,
} = .normal,
curr_attr: Screen.Attr,
reset_attr: Screen.Attr,
cursor_attr: Screen.Attr,

pub const Flags = packed struct {
    screen: enum(u1) { primary, alternate } = .primary,
};

pub fn init(allocator: mem.Allocator, colors: [16]Screen.Color) !Term {
    var primary_screen = try Screen.init(allocator, 80, 24);
    errdefer primary_screen.deinit(allocator);

    var alternate_screen = try Screen.init(allocator, 80, 24);
    errdefer alternate_screen.deinit(allocator);

    return Term{
        .allocator = allocator,
        .colors = colors,
        .primary_screen = primary_screen,
        .alternate_screen = alternate_screen,
        .curr_attr = .{ .fg = colors[7], .bg = colors[0] },
        .reset_attr = .{ .fg = colors[7], .bg = colors[0] },
        .cursor_attr = .{ .fg = colors[0], .bg = colors[7] },
    };
}

pub fn screen(term: *Term) *Screen {
    return switch (term.flags.screen) {
        .primary => &term.primary_screen,
        .alternate => &term.alternate_screen,
    };
}

pub fn feed(term: *Term, cp: u21) error{OutOfMemory}!void {
    switch (term.state) {
        .normal => switch (cp) {
            0x1b => term.state = .escape_start,
            '\r' => term.moveToStartOfLine(),
            '\n' => try term.newline(),
            0x07 => std.log.info("*Bell*", .{}),
            0x08 => term.moveLeft(1),
            else => try term.put(cp),
        },
        .escape_start => switch (cp) {
            '[' => {
                term.params.shrinkRetainingCapacity(0);
                term.state = .csi_params_first;
            },
            0x20...0x2f => term.state = .escape,
            else => {
                std.log.warn("Invalid: {s} {u}", .{ @tagName(term.state), cp });
                if (0x30 <= cp and cp <= 0x7E)
                    term.state = .normal;
            },
        },
        .escape => switch (cp) {
            0x30...0x7e => term.state = .normal,
            0x20...0x2f => {},
            else => {
                std.log.warn("Invalid: {s} {u}", .{ @tagName(term.state), cp });
                if (0x30 <= cp and cp <= 0x7E)
                    term.state = .normal;
            },
        },
        .csi_params_first => switch (cp) {
            0x20...0x2f => term.state = .csi_inter,
            '0'...'9' => {
                try term.params.append(term.allocator, cp - '0');
                term.state = .csi_params;
            },
            'A', 'C', 'P', '@' => {
                try term.params.append(term.allocator, 1);
                term.state = .csi_params;
                try term.feed(cp);
            },
            'm', 'K' => {
                try term.params.append(term.allocator, 0);
                term.state = .csi_params;
                try term.feed(cp);
            },
            'H' => {
                term.state = .csi_params;
                try term.feed(cp);
            },
            else => {
                std.log.warn("Invalid: {s} {u}", .{ @tagName(term.state), cp });
                if (0x40 <= cp and cp <= 0x7E)
                    term.state = .normal;
            },
        },
        .csi_params_next => switch (cp) {
            0x20...0x2f => term.state = .csi_inter,
            '0'...'9' => {
                try term.params.append(term.allocator, cp - '0');
                term.state = .csi_params;
            },
            0x40...0x7e => term.state = .normal,
            else => {
                std.log.warn("Invalid: {s} {u}", .{ @tagName(term.state), cp });
                if (0x40 <= cp and cp <= 0x7E)
                    term.state = .normal;
            },
        },
        .csi_params => switch (cp) {
            0x20...0x2f => term.state = .csi_inter,
            ';' => term.state = .csi_params_next,
            '0'...'9' => {
                const param = &term.params.items[term.params.items.len - 1];
                param.* *= 10;
                param.* += @intCast(u8, cp) - '0';
            },
            'm' => {
                term.selectGraphicRendition();
                term.state = .normal;
            },
            'A' => {
                term.moveUp(term.params.items[0]);
                term.state = .normal;
            },
            'C' => {
                term.moveRight(term.params.items[0]);
                term.state = .normal;
            },
            'H' => {
                try term.params.appendSlice(term.allocator, &[_]usize{ 1, 1 });
                const x = term.params.items[0] -| 1;
                const y = term.params.items[0] -| 1;
                term.moveTo(x, y);
                term.state = .normal;
            },
            'K' => {
                switch (term.params.items[0]) {
                    0 => term.eraseToEndOfLine(),
                    1 => term.eraseFromStartOfLine(),
                    else => std.log.warn("Invalid: {s} {u} {}", .{
                        @tagName(term.state),
                        cp,
                        term.params.items[0],
                    }),
                }
                term.state = .normal;
            },
            'P' => {
                term.deleteGlyphs(term.params.items[0]);
                term.state = .normal;
            },
            '@' => {
                try term.insertBlank(term.params.items[0]);
                term.state = .normal;
            },
            else => {
                std.log.warn("Invalid: {s} {u}", .{ @tagName(term.state), cp });
                if (0x40 <= cp and cp <= 0x7E)
                    term.state = .normal;
            },
        },
        .csi_inter => switch (cp) {
            0x20...0x2f => {},
            else => {
                std.log.warn("Invalid: {s} {u}", .{ @tagName(term.state), cp });
                if (0x40 <= cp and cp <= 0x7E)
                    term.state = .normal;
            },
        },
    }
}

pub fn moveUp(term: *Term, n: usize) void {
    const scr = term.screen();
    scr.moveUp(n);
}

pub fn moveDown(term: *Term, n: usize) void {
    const scr = term.screen();
    _ = scr.moveDown(n);
}

pub fn moveRight(term: *Term, n: usize) void {
    const scr = term.screen();
    scr.moveRight(n);
}

pub fn moveLeft(term: *Term, n: usize) void {
    const scr = term.screen();
    scr.moveLeft(n);
}

pub fn moveTo(term: *Term, x: usize, y: usize) void {
    const scr = term.screen();
    scr.moveTo(x, y);
}

pub fn moveToStartOfLine(term: *Term) void {
    const scr = term.screen();
    scr.moveToStartOfLine();
}

pub fn eraseToEndOfLine(term: *Term) void {
    const scr = term.screen();
    scr.eraseToEndOfLine(term.reset_attr);
}

pub fn eraseFromStartOfLine(term: *Term) void {
    const scr = term.screen();
    scr.eraseFromStartOfLine(term.reset_attr);
}

pub fn deleteGlyphs(term: *Term, n: usize) void {
    const scr = term.screen();
    scr.delete(n, term.reset_attr);
}

pub fn insertBlank(term: *Term, n: usize) !void {
    const scr = term.screen();
    try scr.insertBlank(term.allocator, term.curr_attr, n);
}

pub fn put(term: *Term, cp: u21) !void {
    const scr = term.screen();
    try scr.put(term.allocator, .{ .cp = cp, .attr = term.curr_attr });
}

pub fn newline(term: *Term) !void {
    const scr = term.screen();
    try scr.newline(term.allocator);
}

pub fn selectGraphicRendition(term: *Term) void {
    for (term.params.items) |param| switch (param) {
        0 => term.curr_attr = term.reset_attr, // reset
        1 => term.curr_attr.bold = true, // bold
        30 => term.curr_attr.fg = term.colors[0], // fg black
        31 => term.curr_attr.fg = term.colors[1], // fg red
        32 => term.curr_attr.fg = term.colors[2], // fg green
        33 => term.curr_attr.fg = term.colors[3], // fg yellow
        34 => term.curr_attr.fg = term.colors[4], // fg blue
        35 => term.curr_attr.fg = term.colors[5], // fg magenta
        36 => term.curr_attr.fg = term.colors[6], // fg cyan
        37 => term.curr_attr.fg = term.colors[7], // fg gray
        else => {
            std.log.warn("Invalid SGR param: {}", .{param});
        },
    };
}
