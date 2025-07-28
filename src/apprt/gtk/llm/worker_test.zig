const std = @import("std");
const testing = std.testing;
const worker = @import("worker.zig");
const terminal_context = @import("terminal_context.zig");

test "WorkerRequest.init and deinit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const prompt_text = "test prompt";
    const prompt_copy = try allocator.dupe(u8, prompt_text);

    var request = worker.WorkerRequest{
        .prompt = prompt_copy,
        .terminal_context = null,
        .allocator = allocator,
    };

    try testing.expectEqualStrings(prompt_text, request.prompt);
    try testing.expect(request.terminal_context == null);

    request.deinit();
}

test "WorkerRequest.deinit with terminal context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const prompt_copy = try allocator.dupe(u8, "test prompt");

    const context = terminal_context.TerminalContext{
        .commands = std.ArrayList(terminal_context.TerminalContext.CommandEntry).init(allocator),
        .current_input_full_line = try allocator.dupe(u8, "test context"),
        .allocator = allocator,
    };

    var request = worker.WorkerRequest{
        .prompt = prompt_copy,
        .terminal_context = context,
        .allocator = allocator,
    };

    try testing.expect(request.terminal_context != null);

    // Should not leak memory
    request.deinit();
}

test "WorkerResponse.init and deinit success case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var response = worker.WorkerResponse{
        .success = true,
        .response = try allocator.dupe(u8, "successful response"),
        .error_message = null,
        .allocator = allocator,
    };

    try testing.expect(response.success == true);
    try testing.expect(response.response != null);
    try testing.expect(response.error_message == null);
    try testing.expectEqualStrings("successful response", response.response.?);

    response.deinit();
}

test "WorkerResponse.init and deinit error case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var response = worker.WorkerResponse{
        .success = false,
        .response = null,
        .error_message = try allocator.dupe(u8, "error occurred"),
        .allocator = allocator,
    };

    try testing.expect(response.success == false);
    try testing.expect(response.response == null);
    try testing.expect(response.error_message != null);
    try testing.expectEqualStrings("error occurred", response.error_message.?);

    response.deinit();
}

test "WorkerResponse.deinit with both response and error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var response = worker.WorkerResponse{
        .success = false,
        .response = try allocator.dupe(u8, "response text"),
        .error_message = try allocator.dupe(u8, "error text"),
        .allocator = allocator,
    };

    // Should handle freeing both fields
    response.deinit();
}

test "WorkerCallback type definition" {
    // Test that the callback type can be used correctly
    const TestCallback = worker.WorkerCallback;

    // Define a test callback function
    const testCallback: TestCallback = struct {
        fn callback(response: worker.WorkerResponse, user_data: ?*anyopaque) void {
            _ = response;
            _ = user_data;
            // Test callback that does nothing
        }
    }.callback;

    // Verify the callback type is correct
    try testing.expect(@TypeOf(testCallback) == TestCallback);
}

test "WorkerRequest memory management" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test creating and destroying multiple requests
    for (0..10) |i| {
        var prompt_buf: [100]u8 = undefined;
        const prompt_text = try std.fmt.bufPrint(prompt_buf[0..], "test prompt {}", .{i});

        var request = worker.WorkerRequest{
            .prompt = try allocator.dupe(u8, prompt_text),
            .terminal_context = null,
            .allocator = allocator,
        };

        try testing.expect(request.prompt.len > 0);

        request.deinit();
    }
}

test "WorkerResponse memory management" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test creating and destroying multiple responses
    for (0..10) |i| {
        var response_buf: [100]u8 = undefined;
        const response_text = try std.fmt.bufPrint(response_buf[0..], "response {}", .{i});

        var response = worker.WorkerResponse{
            .success = true,
            .response = try allocator.dupe(u8, response_text),
            .error_message = null,
            .allocator = allocator,
        };

        try testing.expect(response.response.?.len > 0);

        response.deinit();
    }
}
