const std = @import("std");
const testing = std.testing;
const provider_base = @import("provider_base.zig");
const config = @import("../config.zig");

test "BaseProvider.cleanCommandText removes prefixes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "$ ls -la", .expected = "ls -la" },
        .{ .input = "# cat file.txt", .expected = "cat file.txt" },
        .{ .input = "> echo hello", .expected = "echo hello" },
        .{ .input = "```bash\nls -la\n```", .expected = "ls -la" },
        .{ .input = "```shell\npwd", .expected = "pwd" },
        .{ .input = "```sh\necho test", .expected = "echo test" },
        .{ .input = "```\ncd /home", .expected = "cd /home" },
        .{ .input = "   $ ls -la   ", .expected = "ls -la" },
        .{ .input = "\n\t# cat file\n\r", .expected = "cat file" },
    };

    for (test_cases) |test_case| {
        const result = try provider_base.BaseProvider.cleanCommandText(allocator, test_case.input);
        defer allocator.free(result);
        try testing.expectEqualStrings(test_case.expected, result);
    }
}

test "BaseProvider.cleanCommandText removes suffixes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "ls -la\n```", .expected = "ls -la" },
        .{ .input = "pwd```", .expected = "pwd" },
        .{ .input = "echo hello\n```", .expected = "echo hello" },
        .{ .input = "```\nls -la\n```", .expected = "ls -la" },
    };

    for (test_cases) |test_case| {
        const result = try provider_base.BaseProvider.cleanCommandText(allocator, test_case.input);
        defer allocator.free(result);
        try testing.expectEqualStrings(test_case.expected, result);
    }
}

test "BaseProvider.cleanCommandText removes backticks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "`ls -la`", .expected = "ls -la" },
        .{ .input = "`pwd`", .expected = "pwd" },
        .{ .input = "`echo 'hello world'`", .expected = "echo 'hello world'" },
        .{ .input = "ls -la", .expected = "ls -la" }, // No backticks
        .{ .input = "`", .expected = "`" }, // Single backtick (unchanged)
    };

    for (test_cases) |test_case| {
        const result = try provider_base.BaseProvider.cleanCommandText(allocator, test_case.input);
        defer allocator.free(result);
        try testing.expectEqualStrings(test_case.expected, result);
    }
}

test "BaseProvider.cleanCommandText complex cases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test complex case with multiple prefixes/suffixes
    const complex_input = "  ```bash\n$ ls -la\n```  ";
    const result = try provider_base.BaseProvider.cleanCommandText(allocator, complex_input);
    defer allocator.free(result);
    try testing.expectEqualStrings("$ ls -la", result);

    // Test empty string
    const empty_result = try provider_base.BaseProvider.cleanCommandText(allocator, "");
    defer allocator.free(empty_result);
    try testing.expectEqualStrings("", empty_result);

    // Test whitespace only
    const whitespace_result = try provider_base.BaseProvider.cleanCommandText(allocator, "   \n\t  ");
    defer allocator.free(whitespace_result);
    try testing.expectEqualStrings("", whitespace_result);
}

test "BaseProvider.cleanCommandText preserves valid commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_cases = [_][]const u8{
        "ls -la",
        "find . -name '*.txt'",
        "grep -r 'pattern' /path/to/dir",
        "tar -xzvf archive.tar.gz",
        "ssh user@host 'remote command'",
        "awk '{print $1}' file.txt",
        "sed 's/old/new/g' file.txt",
    };

    for (test_cases) |test_case| {
        const result = try provider_base.BaseProvider.cleanCommandText(allocator, test_case);
        defer allocator.free(result);
        try testing.expectEqualStrings(test_case, result);
    }
}

test "Defaults struct values" {
    const defaults = provider_base.Defaults{
        .model = "test-model",
        .temperature = 0.5,
        .max_tokens = 2048,
    };

    try testing.expectEqualStrings("test-model", defaults.model);
    try testing.expect(defaults.temperature == 0.5);
    try testing.expect(defaults.max_tokens == 2048);
    try testing.expectEqualStrings(provider_base.DEFAULT_SYSTEM_PROMPT, defaults.system_prompt);
}

test "DEFAULT_SYSTEM_PROMPT content" {
    const prompt = provider_base.DEFAULT_SYSTEM_PROMPT;

    // Verify it contains expected key phrases
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "helpful Linux command assistant"));
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "Respond with ONLY the command"));
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "Do not include explanations"));
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "Examples:"));
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "ls -la"));
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "find . -name"));
}

test "BaseProvider memory management" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test multiple clean operations don't leak
    for (0..100) |i| {
        var input_buf: [100]u8 = undefined;
        const input = try std.fmt.bufPrint(input_buf[0..], "$ command_{}", .{i});

        const result = try provider_base.BaseProvider.cleanCommandText(allocator, input);
        defer allocator.free(result);

        try testing.expect(result.len > 0);
    }
}
