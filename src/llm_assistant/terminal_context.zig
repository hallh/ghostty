const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.llm_terminal_context);

const terminal = @import("../terminal/main.zig");
const Screen = terminal.Screen;
const Pin = terminal.Pin;
const CoreSurface = @import("../Surface.zig");

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

/// Extract terminal context from any core surface (cross-platform)
pub fn getTerminalContext(allocator: std.mem.Allocator, core_surface: ?*CoreSurface) !?TerminalContext {
    // Guard clause: early return if no surface
    const surface = core_surface orelse return null;

    var context = TerminalContext{
        .allocator = allocator,
    };

    // Capture the recent terminal lines from the core surface
    try captureRecentTerminalLines(surface, &context);

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
    // Guard clause: handle null text case early
    const text = row_text orelse {
        const empty_line = try allocator.dupe(u8, "");
        try recent_lines.append(empty_line);
        total_chars.* += 1;
        return;
    };

    try recent_lines.append(try allocator.dupe(u8, text));
    total_chars.* += text.len + 1;
}

fn addToOlderLines(
    row_text: ?[]const u8,
    older_lines: *std.ArrayList([]u8),
    lines_collected: *usize,
    allocator: std.mem.Allocator,
) !void {
    defer lines_collected.* += 1; // Always increment at end

    // Guard clause: handle null text case early
    const text = row_text orelse {
        const empty_line = try allocator.dupe(u8, "");
        try older_lines.append(empty_line);
        return;
    };

    const trimmed_line = try trimLongLine(text, MAX_LINE_LENGTH, allocator);
    try older_lines.append(trimmed_line);
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

/// Helper function to add lines to terminal content, skipping empty lines
fn addLinesToContent(
    terminal_content: *std.ArrayList(u8),
    lines: *std.ArrayList([]u8),
    starting_line_num: usize,
) !usize {
    var line_num = starting_line_num;
    var i: usize = lines.items.len;

    while (i > 0) {
        i -= 1;
        const line = lines.items[i];

        // Skip empty lines (but keep lines with cursor marker)
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 and !std.mem.containsAtLeast(u8, line, 1, "!!CURSOR!!")) continue;

        try terminal_content.writer().print("{:2}: {s}\n", .{ line_num, line });
        line_num += 1;
    }

    return line_num;
}

/// Capture recent terminal content with cursor position marked
fn captureRecentTerminalLines(core_surface: *CoreSurface, context: *TerminalContext) !void {
    // Access terminal state with proper mutex locking
    core_surface.renderer_state.mutex.lock();
    defer core_surface.renderer_state.mutex.unlock();

    const screen = &core_surface.io.terminal.screen;
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

    line_num = try addLinesToContent(&terminal_content, &older_lines, line_num);
    _ = try addLinesToContent(&terminal_content, &recent_lines, line_num);

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

test "terminal context extraction" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Test basic functionality - more comprehensive tests should be added
    // when we have proper mock terminal surfaces
    var context = TerminalContext{
        .allocator = arena.allocator(),
    };
    defer context.deinit();

    // Test that empty context works
    try testing.expect(context.current_input_full_line == null);
}
