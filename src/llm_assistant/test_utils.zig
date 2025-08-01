const std = @import("std");
const llm = @import("../llm_assistant.zig");

/// Mock LLM Provider for testing
/// This replaces HTTP-level mocking with provider-level mocking for simpler, more reliable tests
pub const MockLLMProvider = struct {
    allocator: std.mem.Allocator,

    // Control what the mock returns
    response_command: ?[]const u8 = null,
    response_error: ?[]const u8 = null,
    error_to_return: ?llm.LLMError = null,
    should_fail_deinit: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        if (self.should_fail_deinit) {
            // Could simulate cleanup issues, but usually not needed
        }
        // Note: We don't own the strings passed in, so no cleanup needed
    }

    /// Convert to LLMProvider interface
    pub fn provider(self: *Self) llm.LLMProvider {
        return llm.LLMProvider{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = llm.LLMProvider.Vtable{
        .request = request,
        .deinit = deinitProvider,
    };

    fn request(ptr: *anyopaque, allocator: std.mem.Allocator, req: llm.LLMRequest) llm.LLMError!llm.LLMResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));

        _ = req; // unused

        if (self.error_to_return) |err| {
            return err;
        }

        const command = if (self.response_command) |cmd|
            try allocator.dupe(u8, cmd)
        else
            try allocator.dupe(u8, "echo 'mock response'");

        const error_msg = if (self.response_error) |err|
            try allocator.dupe(u8, err)
        else
            null;

        return llm.LLMResponse{
            .command = command,
            .error_message = error_msg,
            .is_final = true,
        };
    }

    fn deinitProvider(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        _ = allocator; // unused
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Helper function to create common mock scenarios
pub const MockScenario = struct {
    pub fn success(allocator: std.mem.Allocator, command: []const u8) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .response_command = command,
        };
    }

    pub fn errorScenario(allocator: std.mem.Allocator, err: llm.LLMError) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = err,
        };
    }

    pub fn outOfMemory(allocator: std.mem.Allocator) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = llm.LLMError.OutOfMemory,
        };
    }

    pub fn networkError(allocator: std.mem.Allocator) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = llm.LLMError.NetworkError,
        };
    }

    pub fn authError(allocator: std.mem.Allocator) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = llm.LLMError.AuthenticationError,
        };
    }

    pub fn apiError(allocator: std.mem.Allocator) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = llm.LLMError.APIError,
        };
    }

    pub fn rateLimitError(allocator: std.mem.Allocator) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = llm.LLMError.RateLimitExceeded,
        };
    }
};

/// Mock HTTP client for testing - replaces llm.HTTPClient interface
/// This consolidates the MockHTTPClient implementations from all provider files
pub const MockHTTPClient = struct {
    response_chunks: []const []const u8 = &[_][]const u8{},
    error_to_return: ?anyerror = null,
    status_code: std.http.Status = .ok,
    should_fail_open: bool = false,
    should_fail_write: bool = false,
    should_fail_read: bool = false,

    const Self = @This();

    pub fn init(_: std.mem.Allocator) Self {
        return Self{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn postJSON(
        self: *Self,
        _: []const u8,
        _: []const std.http.Header,
        _: []const u8,
        response_buffer: *std.ArrayList(u8),
    ) !std.http.Status {
        if (self.error_to_return) |err| {
            return err;
        }

        // Simulate response
        if (self.response_chunks.len > 0) {
            try response_buffer.appendSlice(self.response_chunks[0]);
        }

        return self.status_code;
    }
};

// Basic test to ensure MockHTTPClient error handling works
test "MockHTTPClient error handling" {
    const testing = std.testing;

    var mock = MockHTTPClient{
        .error_to_return = error.ConnectionRefused,
    };

    var response_buffer = std.ArrayList(u8).init(testing.allocator);
    defer response_buffer.deinit();

    const result = mock.postJSON("", &[_]std.http.Header{}, "", &response_buffer);
    try testing.expectError(error.ConnectionRefused, result);
}
