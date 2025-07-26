const std = @import("std");
const config = @import("../config.zig");
const llm = @import("../llm_assistant.zig");

const log = std.log.scoped(.anthropic_provider);

/// Anthropic Claude API provider
pub const AnthropicProvider = struct {
    const Self = @This();

    http_client: llm.HTTPClient,
    api_key: []const u8,
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: []const u8,

    /// Default Anthropic API endpoint
    const API_BASE_URL = "https://api.anthropic.com/v1";
    const DEFAULT_MODEL = "claude-3-5-sonnet-20241022";
    const DEFAULT_TEMPERATURE: f32 = 0.1;
    const DEFAULT_MAX_TOKENS: u32 = 1024;
    const DEFAULT_SYSTEM_PROMPT =
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

    /// Anthropic request structure
    const AnthropicRequest = struct {
        model: []const u8,
        max_tokens: u32,
        temperature: f32,
        system: []const u8,
        messages: []const Message,
        stream: bool = false,

        const Message = struct {
            role: []const u8,
            content: []const u8,
        };
    };

    /// Anthropic response structure
    const AnthropicResponse = struct {
        id: ?[]const u8 = null,
        type: ?[]const u8 = null,
        role: ?[]const u8 = null,
        content: []const Content = &.{},
        model: ?[]const u8 = null,
        stop_reason: ?[]const u8 = null,
        stop_sequence: ?[]const u8 = null,
        usage: ?Usage = null,
        @"error": ?ErrorDetail = null,

        const Content = struct {
            type: []const u8,
            text: ?[]const u8 = null,
        };

        const Usage = struct {
            input_tokens: ?u32 = null,
            output_tokens: ?u32 = null,
        };

        const ErrorDetail = struct {
            type: []const u8,
            message: []const u8,
        };
    };

    /// Streaming event structure
    const StreamEvent = struct {
        type: []const u8,
        message: ?AnthropicResponse = null,
        content_block: ?ContentBlock = null,
        delta: ?Delta = null,
        index: ?u32 = null,

        const ContentBlock = struct {
            type: []const u8,
            text: ?[]const u8 = null,
        };

        const Delta = struct {
            type: []const u8,
            text: ?[]const u8 = null,
            stop_reason: ?[]const u8 = null,
        };
    };

    /// Provider vtable implementation
    pub const vtable = llm.LLMProvider.Vtable{
        .request = request,
        .requestStream = requestStream,
        .deinit = deinitProvider,
    };

    /// Initialize Anthropic provider
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        cfg: *const config.Config,
    ) llm.LLMError!*AnthropicProvider {
        const provider = try allocator.create(AnthropicProvider);
        errdefer allocator.destroy(provider);

        // Copy configuration values
        const owned_api_key = try allocator.dupe(u8, api_key);
        errdefer allocator.free(owned_api_key);

        const model = if (cfg.@"ext-llm-model") |m|
            try allocator.dupe(u8, m)
        else
            try allocator.dupe(u8, DEFAULT_MODEL);
        errdefer allocator.free(model);

        const system_prompt = if (cfg.@"ext-llm-system-prompt") |sp|
            try allocator.dupe(u8, sp)
        else
            try allocator.dupe(u8, DEFAULT_SYSTEM_PROMPT);
        errdefer allocator.free(system_prompt);

        provider.* = AnthropicProvider{
            .http_client = llm.HTTPClient.init(allocator),
            .api_key = owned_api_key,
            .model = model,
            .temperature = cfg.@"ext-llm-temperature",
            .max_tokens = cfg.@"ext-llm-max-tokens",
            .system_prompt = system_prompt,
        };

        return provider;
    }

    /// Clean up provider resources
    fn deinitProvider(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    /// Clean up provider resources
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.http_client.deinit();
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.system_prompt);
        allocator.destroy(self);
    }

    /// Make a blocking request
    fn request(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
    ) llm.LLMError!llm.LLMResponse {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));

        // Build request JSON
        const request_json = try self.buildRequestJSON(allocator, req, false);
        defer allocator.free(request_json);

        // Prepare headers
        const headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "anthropic-beta", .value = "messages-2023-12-15" },
        };

        // Make HTTP request
        var response_buffer = std.ArrayList(u8).init(allocator);
        defer response_buffer.deinit();

        const url = API_BASE_URL ++ "/messages";
        const status = try self.http_client.postJSON(url, &headers, request_json, &response_buffer);

        // Parse response
        return self.parseResponse(allocator, response_buffer.items, status);
    }

    /// Make a streaming request
    fn requestStream(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
        callback: llm.StreamCallback,
        user_data: ?*anyopaque,
    ) llm.LLMError!void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));

        // Build streaming request JSON
        const request_json = try self.buildRequestJSON(allocator, req, true);
        defer allocator.free(request_json);

        // Prepare headers
        const headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "anthropic-beta", .value = "messages-2023-12-15" },
            .{ .name = "accept", .value = "text/event-stream" },
        };

        // Create streaming context
        var stream_context = StreamContext{
            .allocator = allocator,
            .callback = callback,
            .user_data = user_data,
            .accumulated_text = std.ArrayList(u8).init(allocator),
        };
        defer stream_context.accumulated_text.deinit();

        // Make streaming HTTP request
        const url = API_BASE_URL ++ "/messages";
        try self.http_client.postJSONStream(url, &headers, request_json, streamCallback, &stream_context);
    }

    /// Context for streaming callbacks
    const StreamContext = struct {
        allocator: std.mem.Allocator,
        callback: llm.StreamCallback,
        user_data: ?*anyopaque,
        accumulated_text: std.ArrayList(u8),
        error_occurred: bool = false,
    };

    /// Callback for streaming data
    fn streamCallback(chunk: []const u8, user_data: ?*anyopaque) void {
        const context: *StreamContext = @ptrCast(@alignCast(user_data.?));

        // Skip if we've already had an error
        if (context.error_occurred) return;

        // Debug logging - show raw chunk during development
        log.debug("Anthropic raw streaming chunk: {s}", .{chunk});

        // Handle server-sent events format
        var lines = std.mem.splitScalar(u8, chunk, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n");

            // Skip empty lines and metadata
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "event:") or
                std.mem.startsWith(u8, trimmed, "id:") or std.mem.startsWith(u8, trimmed, ":"))
            {
                continue;
            }

            // Extract JSON data
            if (std.mem.startsWith(u8, trimmed, "data: ")) {
                const json_data = trimmed[6..]; // Skip "data: " prefix

                // Parse JSON chunk with relaxed parsing
                var parsed = std.json.parseFromSlice(StreamEvent, context.allocator, json_data, .{
                    .ignore_unknown_fields = true,
                }) catch |err| {
                    log.warn("Failed to parse Anthropic streaming chunk: {} - Raw data: {s}", .{ err, json_data });

                    // Signal error to UI by sending an error marker
                    context.error_occurred = true;
                    context.callback("__ERROR__Failed to parse streaming response", context.user_data);
                    return;
                };
                defer parsed.deinit();

                const event = parsed.value;

                // Handle different event types
                if (std.mem.eql(u8, event.type, "content_block_delta")) {
                    if (event.delta) |delta| {
                        if (delta.text) |text| {
                            // Accumulate text and send to callback
                            context.accumulated_text.appendSlice(text) catch {
                                log.warn("Failed to accumulate streaming text", .{});
                                context.error_occurred = true;
                                context.callback("__ERROR__Memory allocation failed", context.user_data);
                                return;
                            };
                            context.callback(text, context.user_data);
                        }
                    }
                } else if (std.mem.eql(u8, event.type, "message_stop")) {
                    log.debug("Anthropic stream completed normally", .{});
                    // Send completion signal to UI
                    context.callback("__COMPLETE__", context.user_data);
                    return;
                } else if (std.mem.eql(u8, event.type, "error")) {
                    log.warn("Anthropic streaming error: {s}", .{json_data});
                    context.error_occurred = true;
                    context.callback("__ERROR__API error during streaming", context.user_data);
                    return;
                }
                // Ignore other event types (ping, message_start, content_block_start, etc.)
            }
        }
    }

    /// Build JSON request payload
    fn buildRequestJSON(
        self: *Self,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
        stream: bool,
    ) llm.LLMError![]u8 {
        const messages = [_]AnthropicRequest.Message{
            .{ .role = "user", .content = req.prompt },
        };

        const api_request = AnthropicRequest{
            .model = req.model orelse self.model,
            .max_tokens = req.max_tokens orelse self.max_tokens,
            .temperature = req.temperature orelse self.temperature,
            .system = req.system_prompt orelse self.system_prompt,
            .messages = &messages,
            .stream = stream,
        };

        return std.json.stringifyAlloc(allocator, api_request, .{}) catch return llm.LLMError.JSONParseError;
    }

    /// Parse API response into LLMResponse
    fn parseResponse(
        self: *Self,
        allocator: std.mem.Allocator,
        response_json: []const u8,
        status: std.http.Status,
    ) llm.LLMError!llm.LLMResponse {
        if (status.class() != .success) {
            // Try to parse error response
            if (std.json.parseFromSlice(AnthropicResponse, allocator, response_json, .{})) |parsed| {
                defer parsed.deinit();
                if (parsed.value.@"error") |err| {
                    const error_msg = try allocator.dupe(u8, err.message);
                    return llm.LLMResponse{
                        .command = "",
                        .error_message = error_msg,
                    };
                }
            } else |_| {}

            return llm.LLMError.APIError;
        }

        // Parse successful response
        const parsed = std.json.parseFromSlice(AnthropicResponse, allocator, response_json, .{}) catch |err| {
            log.err("Failed to parse Anthropic response: {}", .{err});
            return llm.LLMError.JSONParseError;
        };
        defer parsed.deinit();

        const response = parsed.value;

        // Extract command text from content blocks
        var command_text = std.ArrayList(u8).init(allocator);
        defer command_text.deinit();

        for (response.content) |content| {
            if (std.mem.eql(u8, content.type, "text")) {
                if (content.text) |text| {
                    try command_text.appendSlice(text);
                }
            }
        }

        if (command_text.items.len == 0) {
            const error_msg = try allocator.dupe(u8, "No command text received from API");
            return llm.LLMResponse{
                .command = "",
                .error_message = error_msg,
            };
        }

        // Clean up the command text (remove any markdown formatting, etc.)
        const cleaned_command = try self.cleanCommandText(allocator, command_text.items);

        return llm.LLMResponse{
            .command = cleaned_command,
            .is_final = true,
        };
    }

    /// Clean up command text to ensure it's a valid shell command
    fn cleanCommandText(self: *Self, allocator: std.mem.Allocator, text: []const u8) llm.LLMError![]u8 {
        _ = self;

        // Trim whitespace
        const trimmed = std.mem.trim(u8, text, " \t\n\r");

        // Remove markdown code blocks if present
        var cleaned = trimmed;
        if (std.mem.startsWith(u8, cleaned, "```")) {
            if (std.mem.indexOf(u8, cleaned[3..], "\n")) |newline_pos| {
                cleaned = cleaned[3 + newline_pos + 1 ..];
            }
        }
        if (std.mem.endsWith(u8, cleaned, "```")) {
            cleaned = cleaned[0 .. cleaned.len - 3];
        }

        // Remove backticks if present
        if (std.mem.startsWith(u8, cleaned, "`") and std.mem.endsWith(u8, cleaned, "`")) {
            cleaned = cleaned[1 .. cleaned.len - 1];
        }

        // Final trim
        cleaned = std.mem.trim(u8, cleaned, " \t\n\r");

        return try allocator.dupe(u8, cleaned);
    }
};
