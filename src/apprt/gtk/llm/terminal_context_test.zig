const std = @import("std");
const testing = std.testing;
const terminal_context = @import("terminal_context.zig");

test "TerminalContext.init and deinit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = terminal_context.TerminalContext{
        .current_input_full_line = null,
        .allocator = allocator,
    };

    try testing.expect(context.current_input_full_line == null);

    context.deinit();
}

test "TerminalContext.deinit with data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = terminal_context.TerminalContext{
        .current_input_full_line = try allocator.dupe(u8, "test content"),
        .allocator = allocator,
    };

    try testing.expect(context.current_input_full_line != null);

    // Should not leak memory
    context.deinit();
}

test "getTerminalContext with null surface" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try terminal_context.getTerminalContext(allocator, null);
    try testing.expect(result == null);
}

test "getTerminalContext error handling" {
    // This test is limited because we can't easily mock the Surface structure
    // In a real implementation, we would need integration tests with actual Surface objects
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test that function exists and accepts null surface gracefully
    const result = try terminal_context.getTerminalContext(allocator, null);
    try testing.expect(result == null);
}

test "TerminalContext memory management" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test creating and destroying multiple contexts
    for (0..5) |i| {
        var context = terminal_context.TerminalContext{
            .current_input_full_line = null,
            .allocator = allocator,
        };

        // Add some data
        var buf: [100]u8 = undefined;
        const content = try std.fmt.bufPrint(buf[0..], "test content {}", .{i});
        context.current_input_full_line = try allocator.dupe(u8, content);

        context.deinit();
    }
}

test "TerminalContext with content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = terminal_context.TerminalContext{
        .current_input_full_line = try allocator.dupe(u8, "current line content"),
        .allocator = allocator,
    };
    defer context.deinit();

    try testing.expectEqualStrings("current line content", context.current_input_full_line.?);
}
