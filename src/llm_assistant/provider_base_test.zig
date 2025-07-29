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

test "BaseProvider.init success case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a minimal config for testing
    var cfg = config.Config{};
    cfg.@"ext-llm-temperature" = 0.5;
    cfg.@"ext-llm-max-tokens" = 2048;
    cfg.@"ext-llm-system-prompt" = "test system prompt";

    const defaults = provider_base.Defaults{
        .model = "default-model",
    };

    var base = try provider_base.BaseProvider.init(allocator, "test-api-key", "test-model", &cfg, defaults);
    defer base.deinit(allocator);

    // Verify strings were copied properly
    try testing.expectEqualStrings("test-api-key", base.api_key);
    try testing.expectEqualStrings("test-model", base.model);
    try testing.expectEqualStrings("test system prompt", base.system_prompt);
    try testing.expect(base.temperature == 0.5);
    try testing.expect(base.max_tokens == 2048);
}

test "BaseProvider.init with defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a minimal config with nulls to test defaults
    var cfg = config.Config{};
    cfg.@"ext-llm-temperature" = 0.7;
    cfg.@"ext-llm-max-tokens" = 1024;
    cfg.@"ext-llm-system-prompt" = null;

    const defaults = provider_base.Defaults{
        .model = "default-model",
        .temperature = 0.1,
        .max_tokens = 512,
        .system_prompt = "default system prompt",
    };

    var base = try provider_base.BaseProvider.init(allocator, "test-api-key", "provided-model", &cfg, defaults);
    defer base.deinit(allocator);

    // Verify defaults were used
    try testing.expectEqualStrings("test-api-key", base.api_key);
    try testing.expectEqualStrings("provided-model", base.model);
    try testing.expectEqualStrings("default system prompt", base.system_prompt);
    try testing.expect(base.temperature == 0.7); // From config
    try testing.expect(base.max_tokens == 1024); // From config
}

// Mock allocator that fails after a certain number of allocations
const FailingAllocator = struct {
    backing_allocator: std.mem.Allocator,
    fail_after: usize,
    allocation_count: usize = 0,

    const Self = @This();

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.allocation_count += 1;
        if (self.allocation_count > self.fail_after) {
            return null;
        }
        return self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.backing_allocator.rawFree(buf, buf_align, ret_addr);
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = std.mem.Allocator.noRemap,
            },
        };
    }
};

test "BaseProvider.init handles allocation failures properly" {
    var cfg = config.Config{};
    cfg.@"ext-llm-temperature" = 0.5;
    cfg.@"ext-llm-max-tokens" = 2048;
    cfg.@"ext-llm-system-prompt" = "test system prompt";

    const defaults = provider_base.Defaults{
        .model = "default-model",
    };

    // Test failure after first allocation (api_key duplication fails)
    {
        var failing_allocator = FailingAllocator{
            .backing_allocator = testing.allocator,
            .fail_after = 0,
        };
        const allocator = failing_allocator.allocator();

        const result = provider_base.BaseProvider.init(allocator, "test-api-key", "test-model", &cfg, defaults);
        try testing.expectError(error.OutOfMemory, result);
    }

    // Test failure after second allocation (model duplication fails, api_key should be cleaned up)
    {
        var failing_allocator = FailingAllocator{
            .backing_allocator = testing.allocator,
            .fail_after = 1,
        };
        const allocator = failing_allocator.allocator();

        const result = provider_base.BaseProvider.init(allocator, "test-api-key", "test-model", &cfg, defaults);
        try testing.expectError(error.OutOfMemory, result);
    }

    // Test failure after third allocation (system_prompt duplication fails, api_key and model should be cleaned up)
    {
        var failing_allocator = FailingAllocator{
            .backing_allocator = testing.allocator,
            .fail_after = 2,
        };
        const allocator = failing_allocator.allocator();

        const result = provider_base.BaseProvider.init(allocator, "test-api-key", "test-model", &cfg, defaults);
        try testing.expectError(error.OutOfMemory, result);
    }
}
