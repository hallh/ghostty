const std = @import("std");
const testing = std.testing;
const terminal_context = @import("terminal_context.zig");

test "TerminalContext.init and deinit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = terminal_context.TerminalContext{
        .commands = std.ArrayList(terminal_context.TerminalContext.CommandEntry).init(allocator),
        .current_input_full_line = null,
        .allocator = allocator,
    };

    try testing.expect(context.commands.items.len == 0);
    try testing.expect(context.current_input_full_line == null);

    context.deinit();
}

test "TerminalContext.deinit with data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = terminal_context.TerminalContext{
        .commands = std.ArrayList(terminal_context.TerminalContext.CommandEntry).init(allocator),
        .current_input_full_line = try allocator.dupe(u8, "test content"),
        .allocator = allocator,
    };

    // Add some command entries
    try context.commands.append(.{
        .command = try allocator.dupe(u8, "ls -la"),
        .output = try allocator.dupe(u8, "file1.txt\nfile2.txt"),
    });

    try context.commands.append(.{
        .command = try allocator.dupe(u8, "pwd"),
        .output = try allocator.dupe(u8, "/home/user"),
    });

    try testing.expect(context.commands.items.len == 2);
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

test "CommandEntry structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test that CommandEntry can be created and holds data correctly
    const entry = terminal_context.TerminalContext.CommandEntry{
        .command = try allocator.dupe(u8, "test command"),
        .output = try allocator.dupe(u8, "test output"),
    };

    try testing.expectEqualStrings("test command", entry.command);
    try testing.expectEqualStrings("test output", entry.output);

    allocator.free(entry.command);
    allocator.free(entry.output);
}

test "TerminalContext memory management" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test creating and destroying multiple contexts
    for (0..5) |i| {
        var context = terminal_context.TerminalContext{
            .commands = std.ArrayList(terminal_context.TerminalContext.CommandEntry).init(allocator),
            .current_input_full_line = null,
            .allocator = allocator,
        };

        // Add some data
        var buf: [100]u8 = undefined;
        const content = try std.fmt.bufPrint(buf[0..], "test content {}", .{i});
        context.current_input_full_line = try allocator.dupe(u8, content);

        try context.commands.append(.{
            .command = try allocator.dupe(u8, "test command"),
            .output = try allocator.dupe(u8, "test output"),
        });

        context.deinit();
    }
}

test "TerminalContext with many commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = terminal_context.TerminalContext{
        .commands = std.ArrayList(terminal_context.TerminalContext.CommandEntry).init(allocator),
        .current_input_full_line = try allocator.dupe(u8, "current line"),
        .allocator = allocator,
    };
    defer context.deinit();

    // Add many command entries to test scaling
    for (0..100) |i| {
        var cmd_buf: [50]u8 = undefined;
        var out_buf: [50]u8 = undefined;

        const cmd = try std.fmt.bufPrint(cmd_buf[0..], "command_{}", .{i});
        const output = try std.fmt.bufPrint(out_buf[0..], "output_{}", .{i});

        try context.commands.append(.{
            .command = try allocator.dupe(u8, cmd),
            .output = try allocator.dupe(u8, output),
        });
    }

    try testing.expect(context.commands.items.len == 100);
    try testing.expectEqualStrings("command_0", context.commands.items[0].command);
    try testing.expectEqualStrings("command_99", context.commands.items[99].command);
}
