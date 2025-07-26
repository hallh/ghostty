const std = @import("std");
const config = @import("../config.zig");
const llm = @import("../llm_assistant.zig");

const log = std.log.scoped(.gemini_provider);

/// Google Gemini API provider
pub const GeminiProvider = struct {
    const Self = @This();

    http_client: llm.HTTPClient,
    api_key: []const u8,
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: []const u8,

    /// Default Gemini API endpoint
    const API_BASE_URL = "https://generativelanguage.googleapis.com/v1beta";
    const DEFAULT_MODEL = "gemini-1.5-flash";
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

    /// Gemini request structure
    const GeminiRequest = struct {
        contents: []const Content,
        generationConfig: ?GenerationConfig = null,
        systemInstruction: ?SystemInstruction = null,

        const Content = struct {
            role: []const u8,
            parts: []const Part,

            const Part = struct {
                text: []const u8,
            };
        };

        const GenerationConfig = struct {
            temperature: ?f32 = null,
            maxOutputTokens: ?u32 = null,
        };

        const SystemInstruction = struct {
            parts: []const Part,

            const Part = struct {
                text: []const u8,
            };
        };
    };

    /// Gemini response structure
    const GeminiResponse = struct {
        candidates: []const Candidate = &.{},
        promptFeedback: ?PromptFeedback = null,
        usageMetadata: ?UsageMetadata = null,
        @"error": ?ErrorDetail = null,

        const Candidate = struct {
            content: ?Content = null,
            finishReason: ?[]const u8 = null,
            index: ?u32 = null,
            safetyRatings: []const SafetyRating = &.{},

            const Content = struct {
                parts: []const Part = &.{},
                role: ?[]const u8 = null,

                const Part = struct {
                    text: ?[]const u8 = null,
                };
            };

            const SafetyRating = struct {
                category: []const u8,
                probability: []const u8,
            };
        };

        const PromptFeedback = struct {
            safetyRatings: []const SafetyRating = &.{},

            const SafetyRating = struct {
                category: []const u8,
                probability: []const u8,
            };
        };

        const UsageMetadata = struct {
            promptTokenCount: ?u32 = null,
            candidatesTokenCount: ?u32 = null,
            totalTokenCount: ?u32 = null,
        };

        const ErrorDetail = struct {
            code: ?u32 = null,
            message: []const u8,
            status: ?[]const u8 = null,
        };
    };

    /// Provider vtable implementation
    pub const vtable = llm.LLMProvider.Vtable{
        .request = request,
        .requestStream = requestStream,
        .deinit = deinitProvider,
    };

    /// Initialize Gemini provider
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        cfg: *const config.Config,
    ) llm.LLMError!*GeminiProvider {
        const provider = try allocator.create(GeminiProvider);
        errdefer allocator.destroy(provider);

        // Copy configuration values
        const owned_api_key = try allocator.dupe(u8, api_key);
        errdefer allocator.free(owned_api_key);

        const model = cfg.@"ext-llm-model" orelse DEFAULT_MODEL;
        errdefer allocator.free(model);

        const system_prompt = if (cfg.@"ext-llm-system-prompt") |sp|
            try allocator.dupe(u8, sp)
        else
            try allocator.dupe(u8, DEFAULT_SYSTEM_PROMPT);
        errdefer allocator.free(system_prompt);

        provider.* = GeminiProvider{
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
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));
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
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));

        // Build request JSON
        const request_json = try self.buildRequestJSON(allocator, req);
        defer allocator.free(request_json);

        // Build URL with API key
        var url_buffer: [512]u8 = undefined;
        const url = std.fmt.bufPrint(url_buffer[0..], "{s}/models/{s}:generateContent?key={s}", .{ API_BASE_URL, self.model, self.api_key }) catch |err| switch (err) {
            error.NoSpaceLeft => return llm.LLMError.InvalidConfiguration, // URL too long
        };

        // Make HTTP request
        var response_buffer = std.ArrayList(u8).init(allocator);
        defer response_buffer.deinit();

        const headers = [_]std.http.Header{};
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
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));

        // Build request JSON
        const request_json = try self.buildRequestJSON(allocator, req);
        defer allocator.free(request_json);

        // Build URL with API key for streaming
        var url_buffer: [512]u8 = undefined;
        const url = std.fmt.bufPrint(url_buffer[0..], "{s}/models/{s}:streamGenerateContent?key={s}", .{ API_BASE_URL, self.model, self.api_key }) catch |err| switch (err) {
            error.NoSpaceLeft => return llm.LLMError.InvalidConfiguration, // URL too long
        };

        // Create streaming context
        var stream_context = StreamContext{
            .allocator = allocator,
            .callback = callback,
            .user_data = user_data,
            .accumulated_text = std.ArrayList(u8).init(allocator),
        };
        defer stream_context.accumulated_text.deinit();

        const headers = [_]std.http.Header{
            .{ .name = "accept", .value = "text/event-stream" },
        };

        // Make streaming HTTP request
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
        log.debug("Gemini raw streaming chunk: {s}", .{chunk});

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
                var parsed = std.json.parseFromSlice(GeminiResponse, context.allocator, json_data, .{
                    .ignore_unknown_fields = true,
                }) catch |err| {
                    log.warn("Failed to parse Gemini streaming chunk: {} - Raw data: {s}", .{ err, json_data });

                    // Signal error to UI by sending an error marker
                    context.error_occurred = true;
                    context.callback("__ERROR__Failed to parse streaming response", context.user_data);
                    return;
                };
                defer parsed.deinit();

                const stream_chunk = parsed.value;

                // Check for errors
                if (stream_chunk.@"error") |err| {
                    log.warn("Gemini API error: {s}", .{err.message});
                    context.error_occurred = true;
                    const error_msg = std.fmt.allocPrint(context.allocator, "__ERROR__{s}", .{err.message}) catch "__ERROR__API error";
                    defer if (!std.mem.eql(u8, error_msg, "__ERROR__API error")) context.allocator.free(error_msg);
                    context.callback(error_msg, context.user_data);
                    return;
                }

                // Extract content from candidates
                for (stream_chunk.candidates) |candidate| {
                    if (candidate.content) |content| {
                        for (content.parts) |part| {
                            if (part.text) |text| {
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
                    }

                    // Check for finish reason
                    if (candidate.finishReason) |finish_reason| {
                        log.debug("Gemini stream finished with reason: {s}", .{finish_reason});
                        if (std.mem.eql(u8, finish_reason, "STOP")) {
                            // Send completion signal to UI
                            context.callback("__COMPLETE__", context.user_data);
                            return;
                        }
                    }
                }
            }
        }
    }

    /// Build JSON request payload
    fn buildRequestJSON(
        self: *Self,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
    ) llm.LLMError![]u8 {
        const user_part = [_]GeminiRequest.Content.Part{
            .{ .text = req.prompt },
        };

        const contents = [_]GeminiRequest.Content{
            .{ .role = "user", .parts = &user_part },
        };

        const system_part = [_]GeminiRequest.SystemInstruction.Part{
            .{ .text = req.system_prompt orelse self.system_prompt },
        };

        const generation_config = GeminiRequest.GenerationConfig{
            .temperature = req.temperature orelse self.temperature,
            .maxOutputTokens = req.max_tokens orelse self.max_tokens,
        };

        const api_request = GeminiRequest{
            .contents = &contents,
            .generationConfig = generation_config,
            .systemInstruction = .{ .parts = &system_part },
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
            if (std.json.parseFromSlice(GeminiResponse, allocator, response_json, .{})) |parsed| {
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
        const parsed = std.json.parseFromSlice(GeminiResponse, allocator, response_json, .{}) catch |err| {
            log.err("Failed to parse Gemini response: {}", .{err});
            return llm.LLMError.JSONParseError;
        };
        defer parsed.deinit();

        const response = parsed.value;

        // Extract command text from the first candidate
        if (response.candidates.len > 0) {
            const candidate = response.candidates[0];
            if (candidate.content) |content| {
                if (content.parts.len > 0) {
                    if (content.parts[0].text) |text| {
                        // Clean up the command text
                        const cleaned_command = try self.cleanCommandText(allocator, text);

                        return llm.LLMResponse{
                            .command = cleaned_command,
                            .is_final = true,
                        };
                    }
                }
            }
        }

        const error_msg = try allocator.dupe(u8, "No command text received from API");
        return llm.LLMResponse{
            .command = "",
            .error_message = error_msg,
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
