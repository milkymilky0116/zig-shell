const std = @import("std");
const ArrayList = std.ArrayList;
const DefaultCommand = enum {
    echo,
    exit,
    unknown,
    type,
    pwd,
    cd,
};

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

const ErrorEnum = error{ FileNotFound, JoinError, GetEnvError, OutOfMemory, Unexpected };

pub fn findExecutable(path_var: []const u8, arg: []const u8) ErrorEnum![]const u8 {
    var parsed_dir = std.mem.splitScalar(u8, path_var, ':');
    const allocator = std.heap.page_allocator;
    while (parsed_dir.next()) |dir_str| {
        const full_path = std.fs.path.join(allocator, &[_][]const u8{ dir_str, arg }) catch |err| {
            handleError(err);
            return ErrorEnum.FileNotFound;
        };
        defer allocator.free(full_path);
        const file = std.fs.openFileAbsolute(full_path, .{ .mode = .read_only }) catch |err| {
            handleError(err);
            continue;
        };
        defer file.close();
        return dir_str;
    }
    return ErrorEnum.FileNotFound;
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const gpa = general_purpose_allocator.allocator();

    const allocator = std.heap.page_allocator;
    var env_map = std.process.getEnvMap(allocator) catch |err| {
        handleError(err);
        return;
    };
    defer env_map.deinit();

    var dir: std.fs.Dir = undefined;

    while (true) {
        try stdout.print("$ ", .{});
        var buffer: [1024]u8 = undefined;

        const user_input = stdin.readUntilDelimiter(&buffer, '\n') catch |err| {
            handleError(err);
            continue;
        };

        var parsed_input = std.mem.splitScalar(u8, user_input, ' ');
        var user_inputs = ArrayList([]const u8).init(allocator);
        defer user_inputs.deinit();
        while (parsed_input.next()) |str| {
            try user_inputs.append(str);
        }
        const command_str = user_inputs.items[0];
        const command = parseStrToEnum(user_inputs.items[0]);
        switch (command) {
            .echo => {
                const echo_str = try std.mem.join(gpa, " ", user_inputs.items[1..]);
                defer gpa.free(echo_str);
                try stdout.print("{s}\n", .{echo_str});
            },
            .exit => {
                var exit_code: u8 = 0;
                if (user_inputs.items.len > 1) {
                    exit_code = try std.fmt.parseUnsigned(u8, user_inputs.items[1], 10);
                }
                std.process.exit(exit_code);
            },
            .type => {
                const sub_command_str = user_inputs.items[1];
                const sub_command = parseStrToEnum(sub_command_str);
                switch (sub_command) {
                    .unknown => {
                        const path = findExecutable(env_map.get("PATH") orelse "", sub_command_str) catch |err| {
                            handleError(err);
                            try stdout.print("{s}: not found\n", .{sub_command_str});
                            continue;
                        };
                        try stdout.print("{s} is {s}/{s}\n", .{ sub_command_str, path, sub_command_str });
                    },
                    else => {
                        try stdout.print("{s} is a shell builtin\n", .{sub_command_str});
                    },
                }
            },
            .pwd => {
                try stdout.print("{s}\n", .{try std.fs.realpathAlloc(allocator, ".")});
            },
            .cd => {
                var path = user_inputs.items[1];
                if (std.mem.containsAtLeast(u8, path, 1, "~")) {
                    const home = env_map.get("HOME") orelse "/";
                    dir = try std.fs.cwd().openDir(home, .{});
                    defer dir.close();
                    if (path.len > 2) {
                        path = path[2..];
                    }
                    dir.setAsCwd() catch |err| {
                        try stdout.print("fail to read input: {}", .{err});
                    };
                }
                if (std.fs.cwd().openDir(path, .{})) |open_dir| {
                    dir = open_dir;
                    defer dir.close();
                    dir.setAsCwd() catch |err| {
                        try stdout.print("fail to read input: {}", .{err});
                    };
                } else |_| {
                    if (!std.mem.eql(u8, path, "~")) {
                        try stdout.print("cd: {s}: No such file or directory\n", .{path});
                    }
                }
            },
            .unknown => {
                _ = findExecutable(env_map.get("PATH") orelse "", user_inputs.items[0]) catch |err| {
                    handleError(err);
                    try stdout.print("{s}: not found\n", .{command_str});
                    continue;
                };
                var cmd = std.process.Child.init(user_inputs.items, allocator);
                _ = try cmd.spawnAndWait();
            },
        }
    }
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

fn parseStrToEnum(str: []const u8) DefaultCommand {
    if (std.meta.stringToEnum(DefaultCommand, str)) |parsedCommand| {
        return parsedCommand;
    } else {
        return DefaultCommand.unknown;
    }
}
