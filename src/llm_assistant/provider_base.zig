const std = @import("std");
const config = @import("../config.zig");
const llm = @import("../llm_assistant.zig");

/// Default system prompt shared across all providers
pub const DEFAULT_SYSTEM_PROMPT =
    \\You are a helpful Linux command assistant. Respond with ONLY the command that would accomplish the user's request. 
    \\Do not include explanations, markdown formatting, or additional text. 
    \\Return only the raw command that can be executed directly in a Linux terminal.
    \\
    \\Examples:
    \\User: "list all files including hidden ones"
    \\Assistant: ls -la
    \\
    \\User: "find all PDF files in the current directory"
    \\Assistant: find . -name "*.pdf" -type f
;

/// Provider-specific defaults
pub const Defaults = struct {
    model: []const u8,
    temperature: f32 = 0.1,
    max_tokens: u32 = 1024,
    system_prompt: []const u8 = DEFAULT_SYSTEM_PROMPT,
};

/// Base provider with shared functionality
pub const BaseProvider = struct {
    http_client: llm.HTTPClient,
    api_key: []const u8,
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: []const u8,

    const Self = @This();

    /// Initialize BaseProvider with configuration and defaults
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        model: []const u8,
        cfg: *const config.Config,
        defaults: Defaults,
    ) !Self {
        // Copy all strings to ensure they remain valid after config reload
        const owned_api_key = try allocator.dupe(u8, api_key);
        errdefer allocator.free(owned_api_key);

        const owned_model = try allocator.dupe(u8, model);
        errdefer allocator.free(owned_model);

        const owned_system_prompt = try allocator.dupe(u8, cfg.@"ext-llm-system-prompt" orelse defaults.system_prompt);
        errdefer allocator.free(owned_system_prompt);

        return Self{
            .http_client = llm.HTTPClient.init(allocator),
            .api_key = owned_api_key,
            .model = owned_model,
            .temperature = cfg.@"ext-llm-temperature",
            .max_tokens = cfg.@"ext-llm-max-tokens",
            .system_prompt = owned_system_prompt,
        };
    }

    /// Clean up BaseProvider
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // Free all owned strings
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.system_prompt);
        self.http_client.deinit();
    }

    /// Clean command text by removing common prefixes and formatting
    pub fn cleanCommandText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        var cleaned = std.mem.trim(u8, text, " \t\n\r");

        // Remove common command prefixes
        const prefixes = [_][]const u8{
            "$ ",
            "# ",
            "> ",
            "```bash\n",
            "```shell\n",
            "```sh\n",
            "```\n",
        };

        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, cleaned, prefix)) {
                cleaned = cleaned[prefix.len..];
                break;
            }
        }

        // Remove trailing code block markers
        const suffixes = [_][]const u8{
            "\n```",
            "```",
        };

        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, cleaned, suffix)) {
                cleaned = cleaned[0 .. cleaned.len - suffix.len];
                break;
            }
        }

        // Remove surrounding backticks if present
        if (cleaned.len >= 2 and cleaned[0] == '`' and cleaned[cleaned.len - 1] == '`') {
            cleaned = cleaned[1 .. cleaned.len - 1];
        }

        return try allocator.dupe(u8, std.mem.trim(u8, cleaned, " \t\n\r"));
    }
};

test "BaseProvider.cleanCommandText removes prefixes" {
    const testing = std.testing;
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
        const result = try BaseProvider.cleanCommandText(allocator, test_case.input);
        defer allocator.free(result);
        try testing.expectEqualStrings(test_case.expected, result);
    }
}

test "BaseProvider.cleanCommandText removes suffixes" {
    const testing = std.testing;
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
        const result = try BaseProvider.cleanCommandText(allocator, test_case.input);
        defer allocator.free(result);
        try testing.expectEqualStrings(test_case.expected, result);
    }
}

test "BaseProvider.cleanCommandText removes backticks" {
    const testing = std.testing;
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
        const result = try BaseProvider.cleanCommandText(allocator, test_case.input);
        defer allocator.free(result);
        try testing.expectEqualStrings(test_case.expected, result);
    }
}

test "BaseProvider.cleanCommandText complex cases" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test complex case with multiple prefixes/suffixes
    const complex_input = "  ```bash\n$ ls -la\n```  ";
    const result = try BaseProvider.cleanCommandText(allocator, complex_input);
    defer allocator.free(result);
    try testing.expectEqualStrings("$ ls -la", result);

    // Test empty string
    const empty_result = try BaseProvider.cleanCommandText(allocator, "");
    defer allocator.free(empty_result);
    try testing.expectEqualStrings("", empty_result);

    // Test whitespace only
    const whitespace_result = try BaseProvider.cleanCommandText(allocator, "   \n\t  ");
    defer allocator.free(whitespace_result);
    try testing.expectEqualStrings("", whitespace_result);
}

test "BaseProvider.cleanCommandText preserves valid commands" {
    const testing = std.testing;
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
        const result = try BaseProvider.cleanCommandText(allocator, test_case);
        defer allocator.free(result);
        try testing.expectEqualStrings(test_case, result);
    }
}

test "Defaults struct values" {
    const testing = std.testing;
    const defaults = Defaults{
        .model = "test-model",
        .temperature = 0.5,
        .max_tokens = 2048,
    };

    try testing.expectEqualStrings("test-model", defaults.model);
    try testing.expect(defaults.temperature == 0.5);
    try testing.expect(defaults.max_tokens == 2048);
    try testing.expectEqualStrings(DEFAULT_SYSTEM_PROMPT, defaults.system_prompt);
}

test "DEFAULT_SYSTEM_PROMPT content" {
    const testing = std.testing;
    const prompt = DEFAULT_SYSTEM_PROMPT;

    // Verify it contains expected key phrases
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "helpful Linux command assistant"));
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "Respond with ONLY the command"));
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "Do not include explanations"));
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "Examples:"));
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "ls -la"));
    try testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "find . -name"));
}

test "BaseProvider memory management" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test multiple clean operations don't leak
    for (0..100) |i| {
        var input_buf: [100]u8 = undefined;
        const input = try std.fmt.bufPrint(input_buf[0..], "$ command_{}", .{i});

        const result = try BaseProvider.cleanCommandText(allocator, input);
        defer allocator.free(result);

        try testing.expect(result.len > 0);
    }
}

test "BaseProvider.init success case" {
    const testing = std.testing;
    const Config = @import("../config.zig").Config;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a minimal config for testing
    var cfg = Config{};
    cfg.@"ext-llm-temperature" = 0.5;
    cfg.@"ext-llm-max-tokens" = 2048;
    cfg.@"ext-llm-system-prompt" = "test system prompt";

    const defaults = Defaults{
        .model = "default-model",
    };

    var base = try BaseProvider.init(allocator, "test-api-key", "test-model", &cfg, defaults);
    defer base.deinit(allocator);

    // Verify strings were copied properly
    try testing.expectEqualStrings("test-api-key", base.api_key);
    try testing.expectEqualStrings("test-model", base.model);
    try testing.expectEqualStrings("test system prompt", base.system_prompt);
    try testing.expect(base.temperature == 0.5);
    try testing.expect(base.max_tokens == 2048);
}

test "BaseProvider.init with defaults" {
    const testing = std.testing;
    const Config = @import("../config.zig").Config;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a minimal config with nulls to test defaults
    var cfg = Config{};
    cfg.@"ext-llm-temperature" = 0.7;
    cfg.@"ext-llm-max-tokens" = 1024;
    cfg.@"ext-llm-system-prompt" = null;

    const defaults = Defaults{
        .model = "default-model",
        .temperature = 0.1,
        .max_tokens = 512,
        .system_prompt = "default system prompt",
    };

    var base = try BaseProvider.init(allocator, "test-api-key", "provided-model", &cfg, defaults);
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
    const testing = std.testing;
    const Config = @import("../config.zig").Config;
    var cfg = Config{};
    cfg.@"ext-llm-temperature" = 0.5;
    cfg.@"ext-llm-max-tokens" = 2048;
    cfg.@"ext-llm-system-prompt" = "test system prompt";

    const defaults = Defaults{
        .model = "default-model",
    };

    // Test failure after first allocation (api_key duplication fails)
    {
        var failing_allocator = FailingAllocator{
            .backing_allocator = testing.allocator,
            .fail_after = 0,
        };
        const allocator = failing_allocator.allocator();

        const result = BaseProvider.init(allocator, "test-api-key", "test-model", &cfg, defaults);
        try testing.expectError(error.OutOfMemory, result);
    }

    // Test failure after second allocation (model duplication fails, api_key should be cleaned up)
    {
        var failing_allocator = FailingAllocator{
            .backing_allocator = testing.allocator,
            .fail_after = 1,
        };
        const allocator = failing_allocator.allocator();

        const result = BaseProvider.init(allocator, "test-api-key", "test-model", &cfg, defaults);
        try testing.expectError(error.OutOfMemory, result);
    }

    // Test failure after third allocation (system_prompt duplication fails, api_key and model should be cleaned up)
    {
        var failing_allocator = FailingAllocator{
            .backing_allocator = testing.allocator,
            .fail_after = 2,
        };
        const allocator = failing_allocator.allocator();

        const result = BaseProvider.init(allocator, "test-api-key", "test-model", &cfg, defaults);
        try testing.expectError(error.OutOfMemory, result);
    }
}
