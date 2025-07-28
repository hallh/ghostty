const std = @import("std");
const log = std.log.scoped(.llm_terminal_context);

const terminal = @import("../../../terminal/main.zig");
const Screen = terminal.Screen;
const Pin = terminal.Pin;
const Surface = @import("../Surface.zig");

pub const TerminalContext = struct {
    commands: std.ArrayList(CommandEntry),
    current_input_full_line: ?[]u8 = null, // Full line with decorations and cursor marker
    allocator: std.mem.Allocator,

    const CommandEntry = struct {
        command: []u8,
        output: []u8,
    };

    pub fn deinit(self: *TerminalContext) void {
        for (self.commands.items) |entry| {
            self.allocator.free(entry.command);
            self.allocator.free(entry.output);
        }
        self.commands.deinit();
        if (self.current_input_full_line) |full_line| {
            self.allocator.free(full_line);
        }
    }
};

/// Extract terminal context from the active surface
pub fn getTerminalContext(allocator: std.mem.Allocator, surface: ?*Surface) !?TerminalContext {
    if (surface == null) return null;

    var context = TerminalContext{
        .commands = std.ArrayList(TerminalContext.CommandEntry).init(allocator),
        .allocator = allocator,
    };

    // Instead of complex command parsing, just capture the last 30 lines of terminal content
    try captureRecentTerminalLines(surface.?, &context);

    return context;
}

/// Capture the last 5000 characters of terminal content with cursor position marked
fn captureRecentTerminalLines(surface: *Surface, context: *TerminalContext) !void {
    // Access terminal state with proper mutex locking
    surface.core_surface.renderer_state.mutex.lock();
    defer surface.core_surface.renderer_state.mutex.unlock();

    const screen = &surface.core_surface.io.terminal.screen;
    const cursor_pin = screen.cursor.page_pin.*;

    log.debug("Capturing recent terminal content around cursor position y={}", .{cursor_pin.y});

    const max_chars = 5000;
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
        if (captureRowWithCursor(screen, pin, cursor_pin, context.allocator)) |row_text| {
            if (total_chars < max_chars) {
                // Still within the 5000 char limit - keep full lines
                try recent_lines.append(try context.allocator.dupe(u8, row_text));
                total_chars += row_text.len + 1;
            } else if (lines_collected < 30) {
                // Beyond 5000 chars but within 30 line limit - trim long lines
                const trimmed_line = try trimLongLine(row_text, 100, context.allocator);
                try older_lines.append(trimmed_line);
                lines_collected += 1;
            } else {
                // Hit both limits, stop collecting
                context.allocator.free(row_text);
                break;
            }
            context.allocator.free(row_text);
        } else |_| {
            if (total_chars < max_chars) {
                const empty_line = try context.allocator.dupe(u8, "");
                try recent_lines.append(empty_line);
                total_chars += 1;
            } else if (lines_collected < 30) {
                const empty_line = try context.allocator.dupe(u8, "");
                try older_lines.append(empty_line);
                lines_collected += 1;
            } else {
                break;
            }
        }
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

    // Keep first 40% and last 40% of max_length, with "..." in between
    const keep_start = (max_length * 40) / 100;
    const keep_end = (max_length * 40) / 100;
    const ellipsis = "...";

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.appendSlice(line[0..keep_start]);
    try result.appendSlice(ellipsis);
    try result.appendSlice(line[line.len - keep_end ..]);

    return allocator.dupe(u8, result.items);
}
