const std = @import("std");
const gtk = @import("gtk");

pub const History = struct {
    items: std.ArrayList([:0]u8),
    index: ?usize = null,
    max_size: usize = 50,

    pub fn init(allocator: std.mem.Allocator) History {
        return History{
            .items = std.ArrayList([:0]u8).init(allocator),
        };
    }

    pub fn deinit(self: *History) void {
        for (self.items.items) |item| {
            self.items.allocator.free(item);
        }
        self.items.deinit();
    }

    /// Add a text entry to history
    pub fn addEntry(self: *History, text: []const u8) !void {
        // Add to history (null-terminated for GTK compatibility)
        const owned_text = try self.items.allocator.dupeZ(u8, text);
        try self.items.append(owned_text);

        // Limit history size
        if (self.items.items.len > self.max_size) {
            self.items.allocator.free(self.items.orderedRemove(0));
        }

        // Reset history index
        self.index = null;
    }

    /// Navigate through history and update the provided entry widget
    pub fn navigate(self: *History, direction: enum { previous, next }, entry: *gtk.Entry) void {
        if (self.items.items.len == 0) return;

        switch (direction) {
            .previous => {
                if (self.index) |index| {
                    if (index > 0) {
                        self.index = index - 1;
                    }
                } else {
                    self.index = self.items.items.len - 1;
                }
            },
            .next => {
                if (self.index) |index| {
                    if (index < self.items.items.len - 1) {
                        self.index = index + 1;
                    } else {
                        self.index = null;
                    }
                }
            },
        }

        // Update entry text
        if (self.index) |index| {
            const text = self.items.items[index];
            gtk.Editable.setText(entry.as(gtk.Editable), @ptrCast(text.ptr));
        } else {
            gtk.Editable.setText(entry.as(gtk.Editable), "");
        }
    }
};
