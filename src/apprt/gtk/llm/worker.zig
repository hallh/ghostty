const std = @import("std");
const log = std.log.scoped(.llm_worker);
const glib = @import("glib");

const llm = @import("../../../llm_assistant.zig");
const terminal_context = @import("terminal_context.zig");
const prompt_builder = @import("prompt_builder.zig");
const TerminalContext = terminal_context.TerminalContext;

/// NOTE: This worker launches a *one-shot detached thread* for each LLM
/// request and delivers the result back to the UI thread via a glib
/// idle callback.  Other async subsystems in Ghostty (renderer, IO, CF
/// release, etc.) use a long-lived thread + `BlockingQueue` mailbox
/// because they process a continuous stream of messages.  For the LLM
/// assistant the workload is bursty (user presses Ctrl+Shift+K, one
/// request), so spinning up a throw-away thread avoids keeping an idle
/// thread and queue alive.  If we ever introduce streaming responses or
/// high-frequency requests, migrating to the mailbox model or a thread
/// pool would be appropriate.
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
    success: bool,
    response: ?[]u8 = null,
    error_message: ?[]u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WorkerResponse) void {
        if (self.response) |r| {
            self.allocator.free(r);
        }
        if (self.error_message) |e| {
            self.allocator.free(e);
        }
    }
};

pub const WorkerCallback = *const fn (response: WorkerResponse, user_data: ?*anyopaque) void;

/// Process an LLM request in a background thread
pub fn processRequest(
    provider: llm.LLMProvider,
    request: WorkerRequest,
    callback: WorkerCallback,
    user_data: ?*anyopaque,
) void {
    // Create thread data with all needed information
    const thread_data = std.heap.page_allocator.create(ThreadData) catch {
        log.err("Failed to allocate thread data for LLM request", .{});
        return;
    };

    thread_data.* = ThreadData{
        .provider = provider,
        .request = request,
        .callback = callback,
        .user_data = user_data,
    };

    // Spawn background thread for LLM processing
    const thread = std.Thread.spawn(.{}, processRequestBackground, .{thread_data}) catch |err| {
        log.err("Failed to spawn background thread for LLM request: {}", .{err});
        std.heap.page_allocator.destroy(thread_data);

        // Fall back to synchronous processing on main thread as last resort
        processRequestSync(provider, request, callback, user_data);
        return;
    };

    // Detach thread - it will clean itself up
    thread.detach();
}

const ThreadData = struct {
    provider: llm.LLMProvider,
    request: WorkerRequest,
    callback: WorkerCallback,
    user_data: ?*anyopaque,
};

/// Background thread function for processing LLM requests
fn processRequestBackground(thread_data: *ThreadData) void {
    defer std.heap.page_allocator.destroy(thread_data);

    processRequestSync(
        thread_data.provider,
        thread_data.request,
        thread_data.callback,
        thread_data.user_data,
    );
}

/// Synchronous LLM request processing (runs in background thread)
fn processRequestSync(
    provider: llm.LLMProvider,
    request: WorkerRequest,
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
        .success = false,
        .allocator = std.heap.page_allocator,
    };

    if (provider.request(std.heap.page_allocator, llm_request)) |result| {
        // Check if LLM response has an error
        if (result.error_message) |error_msg| {
            response.success = false;
            response.error_message = std.heap.page_allocator.dupe(u8, error_msg) catch null;
        } else {
            response.success = true;
            response.response = std.heap.page_allocator.dupe(u8, result.command) catch null;
            if (response.response == null) {
                response.success = false;
                response.error_message = std.heap.page_allocator.dupe(u8, "Failed to allocate memory for response") catch null;
            }
        }

        // Clean up the LLM response
        var mutable_result = result;
        mutable_result.deinit(std.heap.page_allocator);
    } else |err| {
        response.success = false;
        const error_str = switch (err) {
            llm.LLMError.NetworkError => "Network error. Please check your internet connection.",
            llm.LLMError.AuthenticationError => "Authentication failed. Please check your API key.",
            llm.LLMError.RateLimitExceeded => "Rate limit exceeded. Please try again later.",
            llm.LLMError.APIError => "API error occurred. Please try again.",
            llm.LLMError.JSONParseError => "Invalid response from LLM provider.",
            llm.LLMError.UnsupportedProvider => "Unsupported LLM provider.",
            llm.LLMError.InvalidConfiguration => "LLM provider not configured properly.",
            llm.LLMError.OutOfMemory => "Out of memory error.",
        };
        response.error_message = std.heap.page_allocator.dupe(u8, error_str) catch null;
    }

    // Schedule callback on main thread
    const callback_data = std.heap.page_allocator.create(WorkerCallbackData) catch {
        // If we can't allocate callback data, at least clean up the response
        if (response.response) |text| {
            std.heap.page_allocator.free(text);
        }
        if (response.error_message) |msg| {
            std.heap.page_allocator.free(msg);
        }
        return;
    };

    callback_data.* = WorkerCallbackData{
        .response = response,
        .callback = callback,
        .user_data = user_data,
    };

    _ = glib.idleAdd(handleWorkerCallback, callback_data);
}

const WorkerCallbackData = struct {
    callback: WorkerCallback,
    response: WorkerResponse,
    user_data: ?*anyopaque,
};

fn handleWorkerCallback(data: ?*anyopaque) callconv(.c) c_int {
    const callback_data: *WorkerCallbackData = @ptrCast(@alignCast(data.?));
    defer std.heap.page_allocator.destroy(callback_data);

    callback_data.callback(callback_data.response, callback_data.user_data);
    return 0; // FALSE - remove from idle
}
