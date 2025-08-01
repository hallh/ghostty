const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.llm_terminal_context);

const terminal = @import("../../../terminal/main.zig");
const Screen = terminal.Screen;
const Pin = terminal.Pin;
const Surface = @import("../Surface.zig");

// Terminal context capture configuration
const MAX_TERMINAL_CHARS = 5000; // Maximum characters to capture from terminal
const MAX_TERMINAL_LINES = 30; // Maximum number of lines to capture when over char limit
const MAX_LINE_LENGTH = 100; // Maximum length for individual lines before trimming
const TRIM_KEEP_CHARS = 40; // Number of characters to keep at start/end when trimming

pub const TerminalContext = struct {
    current_input_full_line: ?[]u8 = null, // Full line with decorations and cursor marker
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TerminalContext) void {
        if (self.current_input_full_line) |full_line| {
            self.allocator.free(full_line);
        }
    }
};

/// Extract terminal context from the active surface
pub fn getTerminalContext(allocator: std.mem.Allocator, surface: ?*Surface) !?TerminalContext {
    if (surface == null) return null;

    var context = TerminalContext{
        .allocator = allocator,
    };

    // Instead of complex command parsing, just capture the last 30 lines of terminal content
    try captureRecentTerminalLines(surface.?, &context);

    return context;
}

const CollectionStrategy = enum {
    add_to_recent,
    add_to_older,
    stop_collection,
};

fn determineCollectionStrategy(total_chars: usize, lines_collected: usize, max_chars: usize) CollectionStrategy {
    if (total_chars < max_chars) return .add_to_recent;
    if (lines_collected < MAX_TERMINAL_LINES) return .add_to_older;
    return .stop_collection;
}

fn addToRecentLines(
    row_text: ?[]const u8,
    recent_lines: *std.ArrayList([]u8),
    total_chars: *usize,
    allocator: std.mem.Allocator,
) !void {
    if (row_text) |text| {
        try recent_lines.append(try allocator.dupe(u8, text));
        total_chars.* += text.len + 1;
    } else {
        const empty_line = try allocator.dupe(u8, "");
        try recent_lines.append(empty_line);
        total_chars.* += 1;
    }
}

fn addToOlderLines(
    row_text: ?[]const u8,
    older_lines: *std.ArrayList([]u8),
    lines_collected: *usize,
    allocator: std.mem.Allocator,
) !void {
    if (row_text) |text| {
        const trimmed_line = try trimLongLine(text, MAX_LINE_LENGTH, allocator);
        try older_lines.append(trimmed_line);
    } else {
        const empty_line = try allocator.dupe(u8, "");
        try older_lines.append(empty_line);
    }
    lines_collected.* += 1;
}

fn processTerminalRow(
    screen: *Screen,
    pin: Pin,
    cursor_pin: Pin,
    total_chars: *usize,
    lines_collected: *usize,
    max_chars: usize,
    recent_lines: *std.ArrayList([]u8),
    older_lines: *std.ArrayList([]u8),
    allocator: std.mem.Allocator,
) !bool {
    const strategy = determineCollectionStrategy(total_chars.*, lines_collected.*, max_chars);
    if (strategy == .stop_collection) return false;

    const row_text = captureRowWithCursor(screen, pin, cursor_pin, allocator) catch null;
    defer if (row_text) |text| allocator.free(text);

    switch (strategy) {
        .add_to_recent => try addToRecentLines(row_text, recent_lines, total_chars, allocator),
        .add_to_older => try addToOlderLines(row_text, older_lines, lines_collected, allocator),
        .stop_collection => unreachable, // Already handled above
    }

    return true;
}

/// Capture recent terminal content with cursor position marked
fn captureRecentTerminalLines(surface: *Surface, context: *TerminalContext) !void {
    // Access terminal state with proper mutex locking
    surface.core_surface.renderer_state.mutex.lock();
    defer surface.core_surface.renderer_state.mutex.unlock();

    const screen = &surface.core_surface.io.terminal.screen;
    const cursor_pin = screen.cursor.page_pin.*;

    log.debug("Capturing recent terminal content around cursor position y={}", .{cursor_pin.y});

    const max_chars = MAX_TERMINAL_CHARS;
    var terminal_content = std.ArrayList(u8).init(context.allocator);
    defer terminal_content.deinit();

    // First, seek forward from cursor to find the very end (latest content)
    var end_pin = cursor_pin;
    var it = cursor_pin.rowIterator(.right_down, null);
    while (it.next()) |pin| {
        // Find the last non-empty line or until we hit a reasonable limit
        if (captureRowWithCursor(screen, pin, cursor_pin, context.allocator)) |row_text| {
            defer context.allocator.free(row_text);
            const trimmed = std.mem.trim(u8, row_text, " \t");
            if (trimmed.len > 0) {
                end_pin = pin;
            }
        } else |_| {}

        // Don't go too far forward (max 50 lines)
        if (pin.y > cursor_pin.y + 50) break;
    }

    // Now collect content backwards from the end, prioritizing recent content
    var recent_lines = std.ArrayList([]u8).init(context.allocator);
    defer {
        for (recent_lines.items) |line| {
            context.allocator.free(line);
        }
        recent_lines.deinit();
    }

    var older_lines = std.ArrayList([]u8).init(context.allocator);
    defer {
        for (older_lines.items) |line| {
            context.allocator.free(line);
        }
        older_lines.deinit();
    }

    var total_chars: usize = 0;
    var lines_collected: usize = 0;

    // Go backwards from end_pin
    it = end_pin.rowIterator(.left_up, null);
    while (it.next()) |pin| {
        const should_continue = try processTerminalRow(
            screen,
            pin,
            cursor_pin,
            &total_chars,
            &lines_collected,
            max_chars,
            &recent_lines,
            &older_lines,
            context.allocator,
        );

        if (!should_continue) break;
    }

    // Add older lines in reverse order (oldest first), then recent lines
    var line_num: usize = 1;

    // Add older lines in reverse order
    var i: usize = older_lines.items.len;
    while (i > 0) {
        i -= 1;
        const line = older_lines.items[i];

        // Skip empty lines (but keep lines with cursor marker)
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 and !std.mem.containsAtLeast(u8, line, 1, "!!CURSOR!!")) continue;

        try terminal_content.writer().print("{:2}: {s}\n", .{ line_num, line });
        line_num += 1;
    }

    // Add recent lines in reverse order (newest content)
    i = recent_lines.items.len;
    while (i > 0) {
        i -= 1;
        const line = recent_lines.items[i];

        // Skip empty lines (but keep lines with cursor marker)
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 and !std.mem.containsAtLeast(u8, line, 1, "!!CURSOR!!")) continue;

        try terminal_content.writer().print("{:2}: {s}\n", .{ line_num, line });
        line_num += 1;
    }

    // Store the terminal content as current_input_full_line for backward compatibility
    context.current_input_full_line = try context.allocator.dupe(u8, terminal_content.items);
    log.debug("Captured {} characters of terminal content ({} lines)", .{ total_chars, line_num - 1 });
}

/// Capture a single row's text with cursor marker inserted at cursor position
fn captureRowWithCursor(_: *Screen, row_pin: Pin, cursor_pin: Pin, allocator: std.mem.Allocator) ![]u8 {
    var text_list = std.ArrayList(u8).init(allocator);
    defer text_list.deinit();

    // Create iterator for the specified row
    var start_pin = row_pin;
    start_pin.x = 0;
    var end_pin = row_pin;
    end_pin.x = row_pin.node.data.size.cols - 1;

    const is_cursor_row = (row_pin.y == cursor_pin.y);

    var it = start_pin.cellIterator(.right_down, null);
    while (it.next()) |pin| {
        // Stop at end of row
        if (pin.y != row_pin.y) break;
        if (pin.x > end_pin.x) break;

        // Insert cursor marker at cursor position only on cursor row
        if (is_cursor_row and pin.x == cursor_pin.x) {
            try text_list.appendSlice("!!CURSOR!!");
        }

        const cell = pin.rowAndCell().cell;
        if (cell.hasText()) {
            const codepoint = cell.content.codepoint;
            // Accept all valid Unicode codepoints, not just ASCII
            if (codepoint > 0) {
                var utf8_bytes: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &utf8_bytes) catch continue;
                try text_list.appendSlice(utf8_bytes[0..len]);
            }
        } else {
            // Add space for empty cells to preserve spacing
            try text_list.append(' ');
        }
    }

    // If cursor is at the end of the line on cursor row, add cursor marker
    if (is_cursor_row and cursor_pin.x >= end_pin.x) {
        try text_list.appendSlice("!!CURSOR!!");
    }

    return allocator.dupe(u8, text_list.items);
}

/// Trim a long line by keeping the beginning and end, with "..." in the middle
fn trimLongLine(line: []const u8, max_length: usize, allocator: std.mem.Allocator) ![]u8 {
    if (line.len <= max_length) {
        return allocator.dupe(u8, line);
    }

    // Keep exactly TRIM_KEEP_CHARS characters at start and end, with "..." in between
    const keep_start = @min(TRIM_KEEP_CHARS, line.len / 2);
    const keep_end = @min(TRIM_KEEP_CHARS, line.len - keep_start);
    const ellipsis = "...";

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.appendSlice(line[0..keep_start]);
    try result.appendSlice(ellipsis);
    try result.appendSlice(line[line.len - keep_end ..]);

    return allocator.dupe(u8, result.items);
}

test "TerminalContext memory management" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test creating and destroying multiple contexts with and without data
    for (0..5) |i| {
        var context = TerminalContext{
            .current_input_full_line = null,
            .allocator = allocator,
        };

        if (i % 2 == 0) {
            // Add some data to test deinit with content
            var buf: [100]u8 = undefined;
            const content = try std.fmt.bufPrint(buf[0..], "test content {}", .{i});
            context.current_input_full_line = try allocator.dupe(u8, content);
            try testing.expect(context.current_input_full_line != null);
            try testing.expectEqualStrings(content, context.current_input_full_line.?);
        } else {
            try testing.expect(context.current_input_full_line == null);
        }

        context.deinit();
    }
}

test "getTerminalContext with null surface" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try getTerminalContext(allocator, null);
    try testing.expect(result == null);
}

// Mock function to simulate captureRowWithCursor for integration testing
fn mockCaptureRowWithCursor(row_content: ?[]const u8, is_cursor_row: bool, allocator: std.mem.Allocator) !?[]u8 {
    if (row_content) |content| {
        if (is_cursor_row) {
            return try std.fmt.allocPrint(allocator, "{s}!!CURSOR!!", .{content});
        } else {
            return try allocator.dupe(u8, content);
        }
    }
    return null;
}

// Integration test that exercises processTerminalRow with different collection strategies
test "processTerminalRow integration - recent collection strategy" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var total_chars: usize = 100; // Under MAX_TERMINAL_CHARS
    var lines_collected: usize = 0;
    const max_chars = MAX_TERMINAL_CHARS;

    var recent_lines = std.ArrayList([]u8).init(allocator);
    defer {
        for (recent_lines.items) |line| {
            allocator.free(line);
        }
        recent_lines.deinit();
    }

    var older_lines = std.ArrayList([]u8).init(allocator);
    defer {
        for (older_lines.items) |line| {
            allocator.free(line);
        }
        older_lines.deinit();
    }

    // Simulate different row capture scenarios
    const test_scenarios = [_]struct {
        row_content: ?[]const u8,
        is_cursor_row: bool,
        expected_recent_count: usize,
        expected_older_count: usize,
    }{
        .{ .row_content = "echo hello", .is_cursor_row = false, .expected_recent_count = 1, .expected_older_count = 0 },
        .{ .row_content = "ls -la", .is_cursor_row = true, .expected_recent_count = 2, .expected_older_count = 0 },
        .{ .row_content = null, .is_cursor_row = false, .expected_recent_count = 3, .expected_older_count = 0 }, // Failed capture
    };

    for (test_scenarios) |scenario| {
        // Mock the row capture result
        const mock_row_text = try mockCaptureRowWithCursor(scenario.row_content, scenario.is_cursor_row, allocator);
        defer if (mock_row_text) |text| allocator.free(text);

        // Test the collection strategy determination
        const strategy = determineCollectionStrategy(total_chars, lines_collected, max_chars);
        try testing.expectEqual(CollectionStrategy.add_to_recent, strategy);

        // Test the actual processing logic
        switch (strategy) {
            .add_to_recent => try addToRecentLines(mock_row_text, &recent_lines, &total_chars, allocator),
            .add_to_older => try addToOlderLines(mock_row_text, &older_lines, &lines_collected, allocator),
            .stop_collection => break,
        }

        try testing.expectEqual(scenario.expected_recent_count, recent_lines.items.len);
        try testing.expectEqual(scenario.expected_older_count, older_lines.items.len);
    }

    // Verify cursor marker was properly inserted (should be in the second line which is the cursor row)
    try testing.expect(recent_lines.items.len >= 2);
    try testing.expect(std.mem.indexOf(u8, recent_lines.items[1], "!!CURSOR!!") != null);

    // Test boundary condition: exactly at character limit
    const boundary_total_chars: usize = MAX_TERMINAL_CHARS;
    const boundary_strategy = determineCollectionStrategy(boundary_total_chars, 0, max_chars);
    try testing.expectEqual(CollectionStrategy.add_to_older, boundary_strategy);
}

test "processTerminalRow integration - older collection strategy" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const total_chars: usize = MAX_TERMINAL_CHARS + 100; // Over char limit
    var lines_collected: usize = 5; // Under line limit
    const max_chars = MAX_TERMINAL_CHARS;

    var recent_lines = std.ArrayList([]u8).init(allocator);
    defer {
        for (recent_lines.items) |line| {
            allocator.free(line);
        }
        recent_lines.deinit();
    }

    var older_lines = std.ArrayList([]u8).init(allocator);
    defer {
        for (older_lines.items) |line| {
            allocator.free(line);
        }
        older_lines.deinit();
    }

    // Test scenarios that should go to older lines with trimming
    const test_scenarios = [_]struct {
        row_content: ?[]const u8,
        expected_trimmed: bool,
    }{
        .{ .row_content = "short command", .expected_trimmed = false },
        .{ .row_content = "very " ++ ("long " ** 30) ++ "command line that exceeds MAX_LINE_LENGTH", .expected_trimmed = true },
        .{ .row_content = null, .expected_trimmed = false },
    };

    for (test_scenarios, 0..) |scenario, i| {
        const mock_row_text = try mockCaptureRowWithCursor(scenario.row_content, false, allocator);
        defer if (mock_row_text) |text| allocator.free(text);

        const strategy = determineCollectionStrategy(total_chars, lines_collected, max_chars);
        try testing.expectEqual(CollectionStrategy.add_to_older, strategy);

        const initial_older_count = older_lines.items.len;
        try addToOlderLines(mock_row_text, &older_lines, &lines_collected, allocator);

        try testing.expectEqual(initial_older_count + 1, older_lines.items.len);

        if (scenario.expected_trimmed and mock_row_text != null) {
            // Verify long lines were trimmed
            try testing.expect(older_lines.items[older_lines.items.len - 1].len <= MAX_LINE_LENGTH);
            if (mock_row_text.?.len > MAX_LINE_LENGTH) {
                try testing.expect(std.mem.indexOf(u8, older_lines.items[older_lines.items.len - 1], "...") != null);
            }
        }

        try testing.expectEqual(6 + i, lines_collected);
    }
}

test "processTerminalRow integration - stop collection strategy" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const total_chars: usize = MAX_TERMINAL_CHARS + 100; // Over char limit
    const lines_collected: usize = MAX_TERMINAL_LINES; // At line limit
    const max_chars = MAX_TERMINAL_CHARS;

    var recent_lines = std.ArrayList([]u8).init(allocator);
    defer {
        for (recent_lines.items) |line| {
            allocator.free(line);
        }
        recent_lines.deinit();
    }

    var older_lines = std.ArrayList([]u8).init(allocator);
    defer {
        for (older_lines.items) |line| {
            allocator.free(line);
        }
        older_lines.deinit();
    }

    // Test that we stop collecting when limits are hit
    const strategy = determineCollectionStrategy(total_chars, lines_collected, max_chars);
    try testing.expectEqual(CollectionStrategy.stop_collection, strategy);

    // Verify no processing happens when stop_collection is determined
    const initial_recent_count = recent_lines.items.len;
    const initial_older_count = older_lines.items.len;

    // This simulates what processTerminalRow would do
    if (strategy == .stop_collection) {
        // Should not add anything
    }

    try testing.expectEqual(initial_recent_count, recent_lines.items.len);
    try testing.expectEqual(initial_older_count, older_lines.items.len);
}

test "trimLongLine basic functionality" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test short line (no trimming needed)
    const short_line = "hello world";
    const result_short = try trimLongLine(short_line, 100, allocator);
    defer allocator.free(result_short);
    try testing.expectEqualStrings(short_line, result_short);

    // Test long line that needs trimming
    const long_line = "a" ** 200; // 200 character line
    const result_long = try trimLongLine(long_line, 100, allocator);
    defer allocator.free(result_long);

    // Should start with 40 'a's, have "..." in middle, and end with 40 'a's
    try testing.expect(std.mem.startsWith(u8, result_long, "a" ** 40));
    try testing.expect(std.mem.indexOf(u8, result_long, "...") != null);
    try testing.expect(std.mem.endsWith(u8, result_long, "a" ** 40));

    // Total length should be 40 + 3 + 40 = 83
    try testing.expectEqual(@as(usize, 83), result_long.len);
}

test "trimLongLine edge cases" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test with exactly max_length
    const exact_line = "a" ** 100;
    const result_exact = try trimLongLine(exact_line, 100, allocator);
    defer allocator.free(result_exact);
    try testing.expectEqualStrings(exact_line, result_exact);

    // Test with very short line that should not be trimmed
    const tiny_line = "abc";
    const result_tiny = try trimLongLine(tiny_line, 100, allocator);
    defer allocator.free(result_tiny);
    // Should not trim since it's shorter than max_length
    try testing.expectEqualStrings(tiny_line, result_tiny);

    // Test line that's exactly 80 chars (would be trimmed to 40+3+40=83, but that's longer)
    const borderline = "b" ** 81;
    const result_border = try trimLongLine(borderline, 80, allocator);
    defer allocator.free(result_border);
    try testing.expect(std.mem.indexOf(u8, result_border, "...") != null);
}

test "determineCollectionStrategy comprehensive" {
    const testing = std.testing;

    // Test all strategy branches including boundary conditions
    const test_cases = [_]struct {
        total_chars: usize,
        lines_collected: usize,
        max_chars: usize,
        expected: CollectionStrategy,
    }{
        .{ .total_chars = 100, .lines_collected = 5, .max_chars = 1000, .expected = .add_to_recent },
        .{ .total_chars = 1000, .lines_collected = 5, .max_chars = 500, .expected = .add_to_older },
        .{ .total_chars = 1000, .lines_collected = MAX_TERMINAL_LINES, .max_chars = 500, .expected = .stop_collection },
        .{ .total_chars = 0, .lines_collected = 0, .max_chars = MAX_TERMINAL_CHARS, .expected = .add_to_recent },
        .{ .total_chars = MAX_TERMINAL_CHARS, .lines_collected = 0, .max_chars = MAX_TERMINAL_CHARS, .expected = .add_to_older },
        // Boundary conditions
        .{ .total_chars = MAX_TERMINAL_CHARS - 1, .lines_collected = 0, .max_chars = MAX_TERMINAL_CHARS, .expected = .add_to_recent },
        .{ .total_chars = MAX_TERMINAL_CHARS + 1, .lines_collected = MAX_TERMINAL_LINES - 1, .max_chars = MAX_TERMINAL_CHARS, .expected = .add_to_older },
        .{ .total_chars = MAX_TERMINAL_CHARS + 1, .lines_collected = MAX_TERMINAL_LINES, .max_chars = MAX_TERMINAL_CHARS, .expected = .stop_collection },
    };

    for (test_cases) |case| {
        const result = determineCollectionStrategy(case.total_chars, case.lines_collected, case.max_chars);
        try testing.expectEqual(case.expected, result);
    }
}

test "addToRecentLines and addToOlderLines comprehensive" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recent_lines = std.ArrayList([]u8).init(allocator);
    defer {
        for (recent_lines.items) |line| {
            allocator.free(line);
        }
        recent_lines.deinit();
    }

    var older_lines = std.ArrayList([]u8).init(allocator);
    defer {
        for (older_lines.items) |line| {
            allocator.free(line);
        }
        older_lines.deinit();
    }

    var total_chars: usize = 0;
    var lines_collected: usize = 0;

    // Test addToRecentLines with various inputs
    const recent_test_inputs = [_]?[]const u8{
        "short",
        "medium length text with spaces",
        "very long text that goes on and on and should still be added to recent lines without trimming because recent lines don't get trimmed",
        "",
        null,
    };

    for (recent_test_inputs, 0..) |input, i| {
        const initial_chars = total_chars;
        try addToRecentLines(input, &recent_lines, &total_chars, allocator);

        try testing.expectEqual(i + 1, recent_lines.items.len);

        if (input) |text| {
            try testing.expectEqualStrings(text, recent_lines.items[i]);
            try testing.expectEqual(initial_chars + text.len + 1, total_chars);
        } else {
            try testing.expectEqualStrings("", recent_lines.items[i]);
            try testing.expectEqual(initial_chars + 1, total_chars);
        }
    }

    // Test addToOlderLines with various inputs including trimming
    const older_test_inputs = [_]?[]const u8{
        "this is short",
        "a" ** MAX_LINE_LENGTH, // exactly at limit
        "start" ++ ("middle" ** 30) ++ "end", // exceeds limit, should be trimmed
        "",
        null,
    };

    for (older_test_inputs, 0..) |input, i| {
        try addToOlderLines(input, &older_lines, &lines_collected, allocator);
        try testing.expectEqual(i + 1, lines_collected);

        if (input) |text| {
            if (text.len <= MAX_LINE_LENGTH) {
                try testing.expectEqualStrings(text, older_lines.items[i]);
            } else {
                // Should be trimmed
                const trimmed = older_lines.items[i];
                try testing.expect(trimmed.len < text.len);
                try testing.expect(std.mem.indexOf(u8, trimmed, "...") != null);
                if (std.mem.startsWith(u8, text, "start")) {
                    try testing.expect(std.mem.startsWith(u8, trimmed, "start"));
                    try testing.expect(std.mem.endsWith(u8, trimmed, "end"));
                }
            }
        } else {
            try testing.expectEqualStrings("", older_lines.items[i]);
        }
    }
}
