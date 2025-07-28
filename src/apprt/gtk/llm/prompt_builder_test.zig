const std = @import("std");
const testing = std.testing;
const prompt_builder = @import("prompt_builder.zig");
const terminal_context = @import("terminal_context.zig");

test "createEnhancedPrompt with terminal context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a test terminal context
    var context = terminal_context.TerminalContext{
        .commands = std.ArrayList(terminal_context.TerminalContext.CommandEntry).init(allocator),
        .current_input_full_line = try allocator.dupe(u8, " 1: ls -la\n 2: cd /home\n 3: pwd !!CURSOR!!"),
        .allocator = allocator,
    };
    defer context.deinit();

    const user_prompt = "list all files in the current directory";
    const enhanced = try prompt_builder.createEnhancedPrompt(allocator, user_prompt, context);
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create context without current_input_full_line
    var context = terminal_context.TerminalContext{
        .commands = std.ArrayList(terminal_context.TerminalContext.CommandEntry).init(allocator),
        .current_input_full_line = null,
        .allocator = allocator,
    };
    defer context.deinit();

    const user_prompt = "show system information";
    const enhanced = try prompt_builder.createEnhancedPrompt(allocator, user_prompt, context);
    defer allocator.free(enhanced);

    // Should contain the prompt but not terminal activity section
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "## The user is asking about how to perform certain steps"));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "## They wish to:"));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, user_prompt));

    // Should not contain terminal activity section
    try testing.expect(!std.mem.containsAtLeast(u8, enhanced, 1, "## The recent terminal activity is shown below"));
}

test "createEnhancedPrompt with empty user prompt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = terminal_context.TerminalContext{
        .commands = std.ArrayList(terminal_context.TerminalContext.CommandEntry).init(allocator),
        .current_input_full_line = try allocator.dupe(u8, "test content"),
        .allocator = allocator,
    };
    defer context.deinit();

    const enhanced = try prompt_builder.createEnhancedPrompt(allocator, "", context);
    defer allocator.free(enhanced);

    // Should still contain structure even with empty prompt
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "## The user is asking about"));
    try testing.expect(std.mem.containsAtLeast(u8, enhanced, 1, "## They wish to:"));
}

test "createEnhancedPrompt memory management" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = terminal_context.TerminalContext{
        .commands = std.ArrayList(terminal_context.TerminalContext.CommandEntry).init(allocator),
        .current_input_full_line = try allocator.dupe(u8, "test"),
        .allocator = allocator,
    };
    defer context.deinit();

    // Test multiple allocations don't leak
    for (0..10) |i| {
        var prompt_buf: [50]u8 = undefined;
        const user_prompt = try std.fmt.bufPrint(prompt_buf[0..], "test prompt {}", .{i});

        const enhanced = try prompt_builder.createEnhancedPrompt(allocator, user_prompt, context);
        defer allocator.free(enhanced);

        try testing.expect(enhanced.len > 0);
    }
}
