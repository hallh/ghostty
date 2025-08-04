const std = @import("std");
const llm = @import("../llm_assistant.zig");

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
    ) llm.LLMError!llm.HTTPResponse {
        const allocator = std.heap.page_allocator; // Use page allocator for tests

        if (self.error_to_return != null or @intFromEnum(self.status_code) >= 400) {
            return llm.LLMError.APIError;
        }

        // Simulate successful response
        const response_body = if (self.response_chunks.len > 0)
            self.response_chunks[0]
        else
            "{}";

        return llm.HTTPResponse{
            .body = allocator.dupe(u8, response_body) catch @panic("Out of memory in mock"),
            .allocator = allocator,
        };
    }
};

// Basic test to ensure MockHTTPClient error handling works
test "MockHTTPClient error handling" {
    const testing = std.testing;

    var mock = MockHTTPClient{
        .error_to_return = error.ConnectionRefused,
    };

    const result = mock.postJSON("", &[_]std.http.Header{}, "");
    try testing.expectError(llm.LLMError.APIError, result);
}
