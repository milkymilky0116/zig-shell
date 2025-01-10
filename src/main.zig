const std = @import("std");
const shell = @import("shell/shell.zig");

pub fn main() !void {
    var new_shell = try shell.init();
    while (true) {
        new_shell.run() catch |err| {
            handleError(err);
            continue;
        };
    }
    defer new_shell.pa.destroy(new_shell);
}

fn handleError(err: anyerror) void {
    const timestamp = std.time.timestamp();

    const allocator = std.heap.page_allocator;
    var env_map = std.process.getEnvMap(allocator) catch |envErr| {
        handleError(envErr);
        return;
    };
    defer env_map.deinit();

    const home = env_map.get("HOME") orelse "/";
    const path = std.fmt.allocPrint(allocator, "{s}/Documents/{s}", .{ home, "shell.log" }) catch |fmtErr| {
        std.debug.print("warning: cannot format string: {}\n", .{fmtErr});
        return;
    };
    const file = std.fs.openFileAbsolute(path, .{
        .mode = .read_write,
    }) catch |fileErr| {
        std.debug.print("warning: cannot write error log: {}\n", .{fileErr});
        return;
    };
    defer file.close();

    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const fba_allocator = fba.allocator();

    const err_msg = std.fmt.allocPrint(
        fba_allocator,
        "[{d}] Error: {s}\n",
        .{ timestamp, @errorName(err) },
    ) catch |fmtErr| {
        std.debug.print("warning: cannot format error message: {}\n", .{fmtErr});
        return;
    };
    defer fba_allocator.free(err_msg);

    file.writeAll(err_msg) catch |writeErr| {
        std.debug.print("warning: cannot write to log file: {}\n", .{writeErr});
        return;
    };
}
