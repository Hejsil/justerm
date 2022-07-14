const std = @import("std");

const debug = std.debug;
const math = std.math;
const mem = std.mem;
const testing = std.testing;

const Screen = @This();

width: usize,
height: usize,
cursor: Cursor = Cursor{},
lines: std.ArrayListUnmanaged(Line),

pub const Line = struct {
    glyphs: std.ArrayListUnmanaged(Glyph) = std.ArrayListUnmanaged(Glyph){},
};

pub const Glyph = struct {
    cp: u21,
    attr: Attr,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Attr = struct {
    fg: Color,
    bg: Color,
    bold: bool = false,
};

pub const Cursor = struct {
    // line and col keeps track of what glyph the cursor is pointing at in the data we store.
    line: usize = 0,
    col: usize = 0,

    // The top left of the screen represented the same way as line and col.
    top_line: usize = 0,
    top_col: usize = 0,

    // x and y keeps track of where the cursor is visually on the screen.
    x: usize = 0,
    y: usize = 0,

    // The current line's y cordinate.
    line_y: usize = 0,
};

pub fn init(allocator: mem.Allocator, width: usize, height: usize) !Screen {
    var lines = std.ArrayListUnmanaged(Line){};
    while (lines.items.len < height)
        try lines.append(allocator, .{});

    return Screen{ .lines = lines, .width = width, .height = height };
}

pub fn deinit(screen: *Screen, allocator: mem.Allocator) void {
    for (screen.lines.items) |*line|
        line.glyphs.deinit(allocator);
    screen.lines.deinit(allocator);
}

fn assertValid(screen: Screen) void {
    debug.assert(screen.cursor.top_col <= screen.cursor.col);
    debug.assert(screen.cursor.top_line <= screen.cursor.line);

    // x is allowed to be == width as we need to be able to be at the end of the line.
    debug.assert(screen.cursor.x <= screen.width);
    debug.assert(screen.cursor.y < screen.height);
    debug.assert(screen.cursor.line_y <= screen.cursor.y);
}

/// Given screen.width, figure out the index of the start of the line visually as it would appear
/// in the terminal window.
pub fn visualStartOfLine(screen: Screen) usize {
    screen.assertValid();
    return screen.cursor.col - screen.cursor.x;
}

/// Given screen.width, figure out the index of the end of the line visually as it would appear
/// in the terminal window.
pub fn visualEndOfLine(screen: Screen) usize {
    screen.assertValid();
    return screen.visualStartOfLine() + screen.width;
}

pub fn currentLine(screen: Screen) *Line {
    screen.assertValid();
    return &screen.lines.items[screen.cursor.line];
}

pub fn moveToStartOfLine(screen: *Screen) void {
    screen.assertValid();
    screen.cursor.col = screen.visualStartOfLine();
    screen.cursor.x = 0;
}

fn moveRightIgnoreBounds(screen: *Screen, n: usize) void {
    screen.assertValid();
    screen.cursor.col += n;
    screen.cursor.x += n;
    if (screen.cursor.x > screen.width) {
        screen.cursor.x -= screen.width;
        screen.cursor.y += 1;
    }
}

pub fn moveRight(screen: *Screen, n: usize) void {
    screen.assertValid();

    const new_x = math.min(screen.cursor.x + n, screen.width - 1);
    screen.cursor.col += (new_x - screen.cursor.x);
    screen.cursor.x = new_x;
}

pub fn moveLeft(screen: *Screen, n: usize) void {
    screen.assertValid();
    const new_x = screen.cursor.x -| n;
    screen.cursor.col -= (screen.cursor.x - new_x);
    screen.cursor.x = new_x;
}

pub fn moveUp(screen: *Screen, n: usize) void {
    screen.assertValid();

    var lines_to_move = n;
    while (lines_to_move != 0) {
        // Move up the visual lines of the logical line we are currently on.
        while (lines_to_move != 0 and screen.cursor.x != screen.cursor.col and
            screen.cursor.y != 0)
        {
            lines_to_move -= 1;
            screen.cursor.col -= screen.width;
            screen.cursor.y -= 1;
        }

        if (screen.cursor.y == 0)
            // We are on the first line. Nothing to do
            break;

        if (lines_to_move != 0) {
            // Alright, we need to move up a logical line. This means we have to end up on the
            // last visual line of the new logical lime.
            lines_to_move -= 1;
            screen.cursor.line -= 1;
            screen.cursor.y -= 1;
            const line = screen.currentLine();

            // Place ourselfs on the last visual line at the same visual column as the prev
            // visual line we where on.
            const n_lines = (line.glyphs.items.len + (screen.width - 1)) / screen.width;
            const last_line = n_lines -| 1;
            screen.cursor.col = screen.width * last_line + screen.cursor.x;
        }
    }
}

pub fn moveDown(screen: *Screen, n: usize) usize {
    screen.assertValid();
    var lines_to_move = n;
    while (lines_to_move != 0) {
        const line = screen.currentLine();
        // Move down the visual lines of the logical line we are currently on.
        const n_lines = (line.glyphs.items.len + (screen.width - 1)) / screen.width;
        const end = n_lines * screen.width;
        while (lines_to_move != 0 and screen.cursor.col + screen.width < end and
            screen.cursor.y + 1 < screen.height)
        {
            lines_to_move -= 1;
            screen.cursor.col += screen.width;
            screen.cursor.y += 1;
        }

        if (screen.cursor.y + 1 == screen.height)
            // We are on the last line. Nothing to do
            break;

        if (lines_to_move != 0) {
            lines_to_move -= 1;
            screen.cursor.line += 1;
            screen.cursor.y += 1;
            screen.cursor.col = screen.cursor.x;
        }
    }

    return n - lines_to_move;
}

pub fn moveTo(screen: *Screen, x: usize, y: usize) void {
    screen.assertValid();
    screen.moveUp(math.maxInt(usize));
    screen.moveToStartOfLine();
    screen.moveRight(x);
    _ = screen.moveDown(y);
}

pub fn insertBlank(screen: *Screen, allocator: mem.Allocator, attr: Attr, n: usize) !void {
    screen.assertValid();
    const line = screen.currentLine();
    var i: usize = 0;
    while (i < n) : (i += 1)
        try line.glyphs.insert(allocator, screen.cursor.col, .{ .cp = ' ', .attr = attr });
}

pub fn delete(screen: *Screen, n: usize, reset_attr: Attr) void {
    const line = screen.currentLine();
    const end = screen.visualEndOfLine();
    const start = math.min(screen.cursor.col + n, end);

    // Move everything aver deleted glyphs to where the cursor is
    mem.copy(Glyph, line.glyphs.items[screen.cursor.col..], line.glyphs.items[start..end]);

    const len = end - start;
    mem.set(Glyph, line.glyphs.items[screen.cursor.col + len .. end], .{
        .cp = ' ',
        .attr = reset_attr,
    });
}

pub fn eraseToEndOfLine(screen: *Screen, reset_attr: Attr) void {
    screen.assertValid();
    const line = screen.currentLine();
    const start = math.min(screen.cursor.col, line.glyphs.items.len);
    const ending = screen.visualEndOfLine();
    const end = math.min(ending, line.glyphs.items.len);
    mem.set(Screen.Glyph, line.glyphs.items[start..end], .{ .cp = ' ', .attr = reset_attr });
}

pub fn eraseFromStartOfLine(screen: *Screen, reset_attr: Attr) void {
    screen.assertValid();
    const line = screen.currentLine();
    const start = screen.visualStartOfLine();
    const ending = screen.cursor.col + 1;
    const end = math.min(ending, line.glyphs.items.len);
    mem.set(Screen.Glyph, line.glyphs.items[start..end], .{ .cp = ' ', .attr = reset_attr });
}

pub fn replace(screen: *Screen, allocator: mem.Allocator, glyph: Glyph) !void {
    screen.assertValid();
    const line = screen.currentLine();
    while (line.glyphs.items.len <= screen.cursor.col)
        try line.glyphs.append(allocator, .{ .cp = ' ', .attr = glyph.attr });

    line.glyphs.items[screen.cursor.col] = glyph;
}

pub fn put(screen: *Screen, allocator: mem.Allocator, glyph: Glyph) !void {
    try screen.replace(allocator, glyph);
    screen.moveRightIgnoreBounds(1);
}

pub fn putAsciiString(
    screen: *Screen,
    allocator: mem.Allocator,
    attr: Attr,
    str: []const u8,
) !void {
    for (str) |c|
        try screen.put(allocator, .{ .cp = c, .attr = attr });
}

pub fn newline(screen: *Screen, allocator: mem.Allocator) !void {
    screen.assertValid();
    if (screen.cursor.line + 1 == screen.lines.items.len)
        try screen.lines.append(allocator, .{});

    debug.assert(screen.moveDown(1) == 1);
    screen.cursor.col = screen.visualStartOfLine();
    screen.cursor.x = 0;
}

pub fn renderIterator(_screen: Screen, blank_attr: Attr, cursor_attr: Attr) RenderIterator {
    var screen = _screen;
    screen.moveUp(math.maxInt(usize));
    screen.moveToStartOfLine();
    return .{
        .blank_attr = blank_attr,
        .cursor_attr = cursor_attr,
        .cursor = _screen.cursor,
        .screen = screen,
    };
}

pub const RenderIterator = struct {
    blank_attr: Attr,
    cursor_attr: Attr,
    cursor: Cursor,
    screen: Screen,

    pub fn next(iter: *RenderIterator) ?Glyph {
        const is_cursor = iter.cursor.line == iter.screen.cursor.line and
            iter.cursor.col == iter.screen.cursor.col;
        const is_end_of_line = iter.screen.cursor.x == iter.screen.width;

        if (is_end_of_line) {
            if (is_cursor and iter.cursor.x == 0) {
                // The cursor is at the start of the next visual line, but that line might be
                // empty. In that case, `screen.moveDown` will move to the next logical line
                // instead of to the empty visual line where the cursor is. This is a workaround
                // for that edge case.
                iter.screen.cursor.x = 0;
            } else {
                const lines_moved = iter.screen.moveDown(1);
                if (lines_moved == 0)
                    return null;

                iter.screen.moveToStartOfLine();
            }

            return Glyph{ .cp = '\n', .attr = iter.blank_attr };
        }

        const line = iter.screen.currentLine();
        const has_glyph = iter.screen.cursor.col < line.glyphs.items.len;
        const blank = Glyph{ .cp = ' ', .attr = iter.blank_attr };
        var glyph = if (has_glyph) line.glyphs.items[iter.screen.cursor.col] else blank;
        if (is_cursor)
            glyph.attr = iter.cursor_attr;

        iter.screen.cursor.col += 1;
        iter.screen.cursor.x += 1;
        return glyph;
    }
};

const test_blank = Attr{ .fg = .{ .r = 0, .g = 0, .b = 0 }, .bg = .{ .r = 0, .g = 0, .b = 0 } };

fn expect(screen: Screen, expected: []const u8) !void {
    const cursor = Attr{
        .fg = .{ .r = 0, .g = 0, .b = 0 },
        .bg = .{ .r = 0, .g = 0, .b = 0 },
        .bold = true,
    };
    var it = screen.renderIterator(test_blank, cursor);
    var actual = std.ArrayList(u8).init(testing.allocator);
    defer actual.deinit();

    while (it.next()) |glyph| {
        if (glyph.attr.bold)
            try actual.append('[');
        try actual.writer().print("{u}", .{glyph.cp});
        if (glyph.attr.bold)
            try actual.append(']');
    }

    try testing.expectEqualStrings(expected, actual.items);
}

test "put" {
    const allocator = testing.allocator;
    var screen = try Screen.init(allocator, 10, 4);
    defer screen.deinit(allocator);

    try expect(screen,
        \\[ ]         
        \\          
        \\          
        \\          
    );

    try screen.putAsciiString(allocator, test_blank, "aabbccdde");
    try expect(screen,
        \\aabbccdde[ ]
        \\          
        \\          
        \\          
    );

    try screen.putAsciiString(allocator, test_blank, "e");
    try expect(screen,
        \\aabbccddee
        \\[ ]         
        \\          
        \\          
    );

    try screen.putAsciiString(allocator, test_blank, "ffgghhiijj");
    try expect(screen,
        \\aabbccddee
        \\ffgghhiijj
        \\[ ]         
        \\          
    );
}

test "moveTo" {
    const allocator = testing.allocator;
    var screen = try Screen.init(allocator, 10, 4);
    defer screen.deinit(allocator);

    screen.moveTo(0, 0);
    try expect(screen,
        \\[ ]         
        \\          
        \\          
        \\          
    );

    screen.moveTo(1, 1);
    try expect(screen,
        \\          
        \\ [ ]        
        \\          
        \\          
    );

    screen.moveTo(3, 3);
    try expect(screen,
        \\          
        \\          
        \\          
        \\   [ ]      
    );

    screen.moveTo(4, 4);
    try expect(screen,
        \\          
        \\          
        \\          
        \\    [ ]     
    );

    screen.moveTo(math.maxInt(usize), math.maxInt(usize));
    try expect(screen,
        \\          
        \\          
        \\          
        \\         [ ]
    );

    screen.moveTo(0, 0);
    try screen.putAsciiString(allocator, test_blank, "aabbccddeeffgghhiijj");

    screen.moveTo(0, 0);
    try expect(screen,
        \\[a]abbccddee
        \\ffgghhiijj
        \\          
        \\          
    );

    screen.moveTo(1, 1);
    try expect(screen,
        \\aabbccddee
        \\f[f]gghhiijj
        \\          
        \\          
    );

    screen.moveTo(3, 3);
    try expect(screen,
        \\aabbccddee
        \\ffgghhiijj
        \\          
        \\   [ ]      
    );

    screen.moveTo(4, 4);
    try expect(screen,
        \\aabbccddee
        \\ffgghhiijj
        \\          
        \\    [ ]     
    );

    screen.moveTo(math.maxInt(usize), math.maxInt(usize));
    try expect(screen,
        \\aabbccddee
        \\ffgghhiijj
        \\          
        \\         [ ]
    );
}
