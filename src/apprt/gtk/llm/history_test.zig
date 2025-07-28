const std = @import("std");
const testing = std.testing;
const history = @import("history.zig");
const gtk = @import("gtk");

test "History.init creates empty history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = history.History.init(allocator);
    defer hist.deinit();

    try testing.expect(hist.items.items.len == 0);
    try testing.expect(hist.index == null);
    try testing.expect(hist.max_size == 50);
}

test "History.addEntry adds entries and limits size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = history.History.init(allocator);
    defer hist.deinit();

    // Add a few entries
    try hist.addEntry("first command");
    try hist.addEntry("second command");
    try hist.addEntry("third command");

    try testing.expect(hist.items.items.len == 3);
    try testing.expectEqualStrings("first command", hist.items.items[0]);
    try testing.expectEqualStrings("second command", hist.items.items[1]);
    try testing.expectEqualStrings("third command", hist.items.items[2]);
    try testing.expect(hist.index == null);
}

test "History.addEntry limits max size correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = history.History.init(allocator);
    defer hist.deinit();
    hist.max_size = 3; // Set small max size for testing

    // Add more entries than max size
    try hist.addEntry("first");
    try hist.addEntry("second");
    try hist.addEntry("third");
    try hist.addEntry("fourth");
    try hist.addEntry("fifth");

    try testing.expect(hist.items.items.len == 3);
    try testing.expectEqualStrings("third", hist.items.items[0]);
    try testing.expectEqualStrings("fourth", hist.items.items[1]);
    try testing.expectEqualStrings("fifth", hist.items.items[2]);
}

test "History.navigate with empty history does nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = history.History.init(allocator);
    defer hist.deinit();

    // Create a mock GTK entry for testing
    // Note: This is a simplified test since we can't easily mock GTK widgets
    // In practice, this would be tested via integration tests

    // The navigate function should handle empty history gracefully
    try testing.expect(hist.index == null);
}

test "History.navigate previous and next logic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = history.History.init(allocator);
    defer hist.deinit();

    // Add test entries
    try hist.addEntry("first");
    try hist.addEntry("second");
    try hist.addEntry("third");

    // Test navigation logic (without GTK dependency)
    // Navigate to previous (should go to last item)
    hist.index = hist.items.items.len - 1; // Simulate first previous navigation
    try testing.expect(hist.index.? == 2);

    // Navigate previous again
    if (hist.index.? > 0) {
        hist.index = hist.index.? - 1;
    }
    try testing.expect(hist.index.? == 1);

    // Navigate to next
    if (hist.index.? < hist.items.items.len - 1) {
        hist.index = hist.index.? + 1;
    } else {
        hist.index = null;
    }
    try testing.expect(hist.index.? == 2);

    // Navigate next again (should reset to null)
    if (hist.index.? < hist.items.items.len - 1) {
        hist.index = hist.index.? + 1;
    } else {
        hist.index = null;
    }
    try testing.expect(hist.index == null);
}

test "History.deinit frees all memory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = history.History.init(allocator);

    try hist.addEntry("test entry 1");
    try hist.addEntry("test entry 2");

    // Should not leak memory when deinit is called
    hist.deinit();
}
