const std = @import("std");
const terminal_context = @import("terminal_context.zig");
const TerminalContext = terminal_context.TerminalContext;

/// Create an enhanced prompt that includes terminal context
pub fn createEnhancedPrompt(allocator: std.mem.Allocator, user_prompt: []const u8, context: TerminalContext) ![]u8 {
    var prompt_builder = std.ArrayList(u8).init(allocator);
    defer prompt_builder.deinit();

    // Use the new format that provides terminal context
    try prompt_builder.appendSlice("## The user is asking about how to perform certain steps or actions via their CLI.");

    // Add recent terminal content if available
    if (context.current_input_full_line) |terminal_content| {
        try prompt_builder.appendSlice("## The recent terminal activity is shown below (with line numbers for reference):\n\n");
        try prompt_builder.appendSlice("```\n");
        try prompt_builder.appendSlice(terminal_content);
        try prompt_builder.appendSlice("```\n");

        try prompt_builder.appendSlice("\n## The current state of the active line is the last line. Ignore any decorations that may be present. When returning the suggested CLI command, return only the part of the command that is missing and assume that it will replace the !!CURSOR!! marker.\n");
    }

    // Add the user's request
    try prompt_builder.appendSlice("\n## They wish to:\n\n");
    try prompt_builder.appendSlice(user_prompt);
    try prompt_builder.appendSlice("\n");

    return allocator.dupe(u8, prompt_builder.items);
}

test "createEnhancedPrompt with terminal context" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a test terminal context
    var context = TerminalContext{
        .current_input_full_line = try allocator.dupe(u8, " 1: ls -la\n 2: cd /home\n 3: pwd !!CURSOR!!"),
        .allocator = allocator,
    };
    defer context.deinit();

    const user_prompt = "list all files in the current directory";
    const enhanced = try createEnhancedPrompt(allocator, user_prompt, context);
    defer allocator.free(enhanced);

    // Verify the enhanced prompt contains expected elements
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "## The user is asking about how to perform certain steps"));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "## The recent terminal activity is shown below"));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "ls -la"));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "!!CURSOR!!"));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "## They wish to:"));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, user_prompt));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "replace the !!CURSOR!! marker"));
}

test "createEnhancedPrompt without terminal context" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create context without current_input_full_line
    var context = TerminalContext{
        .current_input_full_line = null,
        .allocator = allocator,
    };
    defer context.deinit();

    const user_prompt = "show system information";
    const enhanced = try createEnhancedPrompt(allocator, user_prompt, context);
    defer allocator.free(enhanced);

    // Should contain the prompt but not terminal activity section
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "## The user is asking about how to perform certain steps"));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "## They wish to:"));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, user_prompt));

    // Should not contain terminal activity section
    try testing.expect(!std.mem.containsAtLeast(u8, enhanced, 1, "## The recent terminal activity is shown below"));
}

test "createEnhancedPrompt with empty user prompt" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = TerminalContext{
        .current_input_full_line = try allocator.dupe(u8, "test content"),
        .allocator = allocator,
    };
    defer context.deinit();

    const enhanced = try createEnhancedPrompt(allocator, "", context);
    defer allocator.free(enhanced);

    // Should still contain structure even with empty prompt
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "## The user is asking about"));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "## They wish to:"));
}

test "createEnhancedPrompt memory management" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = TerminalContext{
        .current_input_full_line = try allocator.dupe(u8, "test"),
        .allocator = allocator,
    };
    defer context.deinit();

    // Test multiple allocations don't leak
    for (0..10) |i| {
        var prompt_buf: [50]u8 = undefined;
        const user_prompt = try std.fmt.bufPrint(prompt_buf[0..], "test prompt {}", .{i});

        const enhanced = try createEnhancedPrompt(allocator, user_prompt, context);
        defer allocator.free(enhanced);

        try testing.expect(enhanced.len > 0);
    }
}
