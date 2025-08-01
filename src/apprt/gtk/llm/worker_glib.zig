const std = @import("std");
const log = std.log.scoped(.llm_worker_glib);
const glib = @import("glib");

const llm = @import("../../../llm_assistant.zig");
const worker_core = @import("../../../llm_assistant/worker_core.zig");
pub const WorkerRequest = worker_core.WorkerRequest;
pub const WorkerResponse = worker_core.WorkerResponse;
pub const WorkerCallback = worker_core.WorkerCallback;
pub const CallbackScheduler = worker_core.CallbackScheduler;

/// GTK/GLib implementation of the callback scheduler
const GLibScheduler = struct {
    const Self = @This();

    fn schedule(ptr: *anyopaque, callback: WorkerCallback, response: WorkerResponse, user_data: ?*anyopaque) void {
        _ = ptr; // unused in this implementation

        const callback_data = std.heap.page_allocator.create(WorkerCallbackData) catch {
            // If we can't allocate callback data, at least clean up the response
            var mutable_response = response;
            mutable_response.deinit();
            return;
        };

        callback_data.* = WorkerCallbackData{
            .response = response,
            .callback = callback,
            .user_data = user_data,
        };

        _ = glib.idleAdd(handleWorkerCallback, callback_data);
    }

    fn asCallbackScheduler(self: *Self) CallbackScheduler {
        return CallbackScheduler{
            .ptr = self,
            .vtable = &.{ .schedule = schedule },
        };
    }
};

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

/// Process an LLM request in a background thread using GLib for callback scheduling
pub fn processRequest(
    provider: llm.LLMProvider,
    request: WorkerRequest,
    callback: WorkerCallback,
    user_data: ?*anyopaque,
) void {
    var scheduler = GLibScheduler{};
    const callback_scheduler = scheduler.asCallbackScheduler();

    worker_core.processRequest(provider, request, callback_scheduler, callback, user_data);
}
