const std = @import("std");
const log = std.log.scoped(.llm_worker_core);

const llm = @import("../llm_assistant.zig");
const terminal_context = @import("terminal_context.zig");
const prompt_builder = @import("prompt_builder.zig");
const TerminalContext = terminal_context.TerminalContext;
const i18n = @import("../os/i18n.zig");

/// Cross-platform callback scheduler interface
pub const CallbackScheduler = struct {
    ptr: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        schedule: *const fn (ptr: *anyopaque, callback: WorkerCallback, response: WorkerResponse, user_data: ?*anyopaque) void,
    };

    pub fn schedule(self: CallbackScheduler, callback: WorkerCallback, response: WorkerResponse, user_data: ?*anyopaque) void {
        self.vtable.schedule(self.ptr, callback, response, user_data);
    }
};

pub const WorkerRequest = struct {
    prompt: []const u8,
    terminal_context: ?TerminalContext = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WorkerRequest) void {
        self.allocator.free(self.prompt);
        if (self.terminal_context) |*ctx| {
            ctx.deinit();
        }
    }
};

pub const WorkerResponse = struct {
    status: enum { ok, err },
    text: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WorkerResponse) void {
        self.allocator.free(self.text);
    }
};

pub const WorkerCallback = *const fn (response: WorkerResponse, user_data: ?*anyopaque) void;

/// Helper function to create a success response
fn makeSuccess(allocator: std.mem.Allocator, text: []const u8) WorkerResponse {
    return WorkerResponse{
        .status = .ok,
        .text = allocator.dupe(u8, text) catch return makeError(allocator, std.mem.span(i18n._("Failed to allocate memory for response"))),
        .allocator = allocator,
    };
}

/// Helper function to create an error response
fn makeError(allocator: std.mem.Allocator, text: []const u8) WorkerResponse {
    return WorkerResponse{
        .status = .err,
        .text = allocator.dupe(u8, text) catch @panic("Out of memory creating error response"),
        .allocator = allocator,
    };
}

/// Helper function to get error message from LLM error
fn getErrorMessage(err: llm.LLMError) []const u8 {
    const msg_ptr = switch (err) {
        llm.LLMError.NetworkError => i18n._("Network error. Please check your internet connection."),
        llm.LLMError.AuthenticationError => i18n._("Authentication failed. Please check your API key."),
        llm.LLMError.RateLimitExceeded => i18n._("Rate limit exceeded. Please try again later."),
        llm.LLMError.APIError => i18n._("API error occurred. Please try again."),
        llm.LLMError.JSONParseError => i18n._("Invalid response from LLM provider."),
        llm.LLMError.UnsupportedProvider => i18n._("Unsupported LLM provider."),
        llm.LLMError.InvalidConfiguration => i18n._("LLM provider not configured properly."),
        llm.LLMError.OutOfMemory => i18n._("Out of memory error."),
    };
    return std.mem.span(msg_ptr);
}

/// Process an LLM request in a background thread
pub fn processRequest(
    provider: llm.LLMProvider,
    request: WorkerRequest,
    scheduler: CallbackScheduler,
    callback: WorkerCallback,
    user_data: ?*anyopaque,
) void {
    // Create thread data with all needed information
    const thread_data = std.heap.page_allocator.create(ThreadData) catch {
        log.err("Failed to allocate thread data for LLM request", .{});

        // Schedule async error callback
        const error_response = makeError(std.heap.page_allocator, std.mem.span(i18n._("Failed to allocate thread data for LLM request")));
        scheduler.schedule(callback, error_response, user_data);
        return;
    };

    thread_data.* = ThreadData{
        .provider = provider,
        .request = request,
        .scheduler = scheduler,
        .callback = callback,
        .user_data = user_data,
    };

    // Spawn background thread for LLM processing
    const thread = std.Thread.spawn(.{}, processRequestBackground, .{thread_data}) catch |err| {
        log.err("Failed to spawn background thread for LLM request: {}", .{err});
        std.heap.page_allocator.destroy(thread_data);

        // Schedule async error callback
        const error_response = makeError(std.heap.page_allocator, std.mem.span(i18n._("Failed to spawn background thread for LLM request")));
        scheduler.schedule(callback, error_response, user_data);
        return;
    };

    // Detach thread - it will clean itself up
    thread.detach();
}

const ThreadData = struct {
    provider: llm.LLMProvider,
    request: WorkerRequest,
    scheduler: CallbackScheduler,
    callback: WorkerCallback,
    user_data: ?*anyopaque,
};

/// Background thread function for processing LLM requests
fn processRequestBackground(thread_data: *ThreadData) void {
    defer std.heap.page_allocator.destroy(thread_data);

    processRequestSync(
        thread_data.provider,
        thread_data.request,
        thread_data.scheduler,
        thread_data.callback,
        thread_data.user_data,
    );
}

/// Synchronous LLM request processing (runs in background thread)
fn processRequestSync(
    provider: llm.LLMProvider,
    request: WorkerRequest,
    scheduler: CallbackScheduler,
    callback: WorkerCallback,
    user_data: ?*anyopaque,
) void {
    // Create a thread-safe copy of the request
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const prompt = if (request.terminal_context) |ctx|
        prompt_builder.createEnhancedPrompt(allocator, request.prompt, ctx) catch request.prompt
    else
        request.prompt;

    const llm_request = llm.LLMRequest{
        .prompt = prompt,
    };

    // Make the request
    var response = WorkerResponse{
        .status = .ok,
        .text = std.heap.page_allocator.dupe(u8, "") catch @panic("Out of memory for initial response text"),
        .allocator = std.heap.page_allocator,
    };

    // Make the request and handle errors with guard clauses
    const result = provider.request(std.heap.page_allocator, llm_request) catch |err| {
        const error_str = getErrorMessage(err);
        std.heap.page_allocator.free(response.text);
        response.text = std.heap.page_allocator.dupe(u8, error_str) catch @panic("Out of memory for error message");
        response.status = .err;

        // Schedule callback
        scheduler.schedule(callback, response, user_data);
        return;
    };

    // Clean up the LLM response when we're done
    defer {
        var mutable_result = result;
        mutable_result.deinit();
    }

    // Check for API-level errors first
    if (result.status == .err) {
        std.heap.page_allocator.free(response.text);
        response.text = std.heap.page_allocator.dupe(u8, result.text) catch @panic("Out of memory for error message");
        response.status = .err;

        // Schedule callback
        scheduler.schedule(callback, response, user_data);
        return;
    }

    // Success case
    std.heap.page_allocator.free(response.text);
    response.text = std.heap.page_allocator.dupe(u8, result.text) catch @panic("Out of memory for response text");
    response.status = .ok;

    // Schedule callback
    scheduler.schedule(callback, response, user_data);
}

test "WorkerRequest lifecycle" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test basic request without terminal context
    {
        const prompt_text = "test prompt";
        const prompt_copy = try allocator.dupe(u8, prompt_text);

        var request = WorkerRequest{
            .prompt = prompt_copy,
            .terminal_context = null,
            .allocator = allocator,
        };

        try testing.expectEqualStrings(prompt_text, request.prompt);
        try testing.expect(request.terminal_context == null);
        request.deinit();
    }

    // Test request with terminal context
    {
        const prompt_copy = try allocator.dupe(u8, "test prompt");
        const context = terminal_context.TerminalContext{
            .current_input_full_line = try allocator.dupe(u8, "test context"),
            .allocator = allocator,
        };

        var request = WorkerRequest{
            .prompt = prompt_copy,
            .terminal_context = context,
            .allocator = allocator,
        };

        try testing.expect(request.terminal_context != null);
        request.deinit();
    }
}

test "WorkerResponse lifecycle" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ResponseStatus = @TypeOf(@as(WorkerResponse, undefined).status);
    const test_cases = [_]struct {
        status: ResponseStatus,
        text: []const u8,
        description: []const u8,
    }{
        .{ .status = .ok, .text = "successful response", .description = "success case" },
        .{ .status = .err, .text = "error occurred", .description = "error case" },
    };

    for (test_cases) |case| {
        var response = WorkerResponse{
            .status = case.status,
            .text = try allocator.dupe(u8, case.text),
            .allocator = allocator,
        };

        try testing.expect(response.status == case.status);
        try testing.expect(response.text.len > 0);
        try testing.expectEqualStrings(case.text, response.text);
        response.deinit();
    }
}

test "getErrorMessage covers all error types" {
    const testing = std.testing;

    const error_cases = [_]llm.LLMError{
        llm.LLMError.NetworkError,
        llm.LLMError.AuthenticationError,
        llm.LLMError.RateLimitExceeded,
        llm.LLMError.APIError,
        llm.LLMError.JSONParseError,
        llm.LLMError.UnsupportedProvider,
        llm.LLMError.InvalidConfiguration,
        llm.LLMError.OutOfMemory,
    };

    for (error_cases) |err| {
        const message = getErrorMessage(err);
        try testing.expect(message.len > 0);
    }
}

test "makeSuccess and makeError" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test success response
    {
        const success_text = "Command executed successfully";
        var success_response = makeSuccess(allocator, success_text);
        defer success_response.deinit();

        try testing.expectEqual(@as(@TypeOf(success_response.status), .ok), success_response.status);
        try testing.expectEqualStrings(success_text, success_response.text);
    }

    // Test error response
    {
        const error_text = "An error occurred";
        var error_response = makeError(allocator, error_text);
        defer error_response.deinit();

        try testing.expectEqual(@as(@TypeOf(error_response.status), .err), error_response.status);
        try testing.expectEqualStrings(error_text, error_response.text);
    }
}
