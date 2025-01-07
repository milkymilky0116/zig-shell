const std = @import("std");
const ArrayList = std.ArrayList;
const DefaultCommand = enum {
    echo,
    exit,
    unknown,
    type,
};
var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const gpa = general_purpose_allocator.allocator();
    while (true) {
        try stdout.print("$ ", .{});

        var buffer: [1024]u8 = undefined;
        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');
        var parsed_input = std.mem.splitScalar(u8, user_input, ' ');

        const allocator = std.heap.page_allocator;
        var commands = ArrayList([]const u8).init(allocator);
        defer commands.deinit();
        while (parsed_input.next()) |str| {
            try commands.append(str);
        }
        const command_str = commands.items[0];
        const command = parseStrToEnum(commands.items[0]);
        switch (command) {
            .echo => {
                const echo_str = try std.mem.join(gpa, " ", commands.items[1..]);
                defer gpa.free(echo_str);
                std.debug.print("{s}\n", .{echo_str});
            },
            .exit => {
                const exit_code = try std.fmt.parseUnsigned(u8, commands.items[1], 10);
                std.process.exit(exit_code);
            },
            .type => {
                const sub_command_str = commands.items[1];
                const sub_command = parseStrToEnum(sub_command_str);
                switch (sub_command) {
                    .unknown => {
                        std.debug.print("{s}: not found\n", .{sub_command_str});
                    },
                    else => {
                        std.debug.print("{s} is a shell builtin\n", .{sub_command_str});
                    },
                }
            },
            .unknown => {
                std.debug.print("{s}: command not found\n", .{command_str});
            },
        }
    }
}

fn parseStrToEnum(str: []const u8) DefaultCommand {
    if (std.meta.stringToEnum(DefaultCommand, str)) |parsedCommand| {
        return parsedCommand;
    } else {
        return DefaultCommand.unknown;
    }
}
