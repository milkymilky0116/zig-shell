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

const ErrorEnum = error{ FileNotFound, PrintError, UserInputError, JoinError, ExecuteError, Unexpected };
var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
pub const Shell = struct {
    stdout: std.io.Writer(std.fs.File, std.posix.WriteError, std.fs.File.write),
    stdin: std.io.Reader(std.fs.File, std.posix.ReadError, std.fs.File.read),
    env_map: std.process.EnvMap,
    gpa: std.mem.Allocator,
    pa: std.mem.Allocator,
    dir: std.fs.Dir,
    pub fn run(self: *Shell) !void {
        self.stdout.print("$ ", .{}) catch {
            return ErrorEnum.PrintError;
        };
        var buffer: [1024]u8 = undefined;

        const user_input = self.stdin.readUntilDelimiter(&buffer, '\n') catch {
            return ErrorEnum.UserInputError;
        };

        var parsed_input = std.mem.splitScalar(u8, user_input, ' ');
        var user_inputs = ArrayList([]const u8).init(self.pa);
        while (parsed_input.next()) |str| {
            user_inputs.append(str) catch {
                return ErrorEnum.Unexpected;
            };
        }
        const command_str = user_inputs.items[0];
        const command = parseStrToEnum(user_inputs.items[0]);
        switch (command) {
            .echo => {
                const echo_str = std.mem.join(self.gpa, " ", user_inputs.items[1..]) catch {
                    return ErrorEnum.JoinError;
                };
                defer self.gpa.free(echo_str);
                self.stdout.print("{s}\n", .{echo_str}) catch {
                    return ErrorEnum.PrintError;
                };
            },
            .exit => {
                var exit_code: u8 = 0;
                if (user_inputs.items.len > 1) {
                    exit_code = std.fmt.parseUnsigned(u8, user_inputs.items[1], 10) catch {
                        return ErrorEnum.Unexpected;
                    };
                }
                std.process.exit(exit_code);
            },
            .type => {
                const sub_command_str = user_inputs.items[1];
                const sub_command = parseStrToEnum(sub_command_str);
                switch (sub_command) {
                    .unknown => {
                        const path = findExecutable(self.env_map.get("PATH") orelse "", sub_command_str) catch {
                            self.stdout.print("{s}: not found\n", .{sub_command_str}) catch {
                                return ErrorEnum.PrintError;
                            };
                            return ErrorEnum.FileNotFound;
                        };
                        self.stdout.print("{s} is {s}/{s}\n", .{ sub_command_str, path, sub_command_str }) catch {
                            return ErrorEnum.PrintError;
                        };
                    },
                    else => {
                        self.stdout.print("{s} is a shell builtin\n", .{sub_command_str}) catch {
                            return ErrorEnum.PrintError;
                        };
                    },
                }
            },
            .pwd => {
                self.stdout.print("{s}\n", .{try std.fs.realpathAlloc(self.pa, ".")}) catch {
                    return ErrorEnum.PrintError;
                };
            },
            .cd => {
                var path = user_inputs.items[1];
                if (std.mem.containsAtLeast(u8, path, 1, "~")) {
                    const home = self.env_map.get("HOME") orelse "/";
                    self.dir = std.fs.cwd().openDir(home, .{}) catch {
                        return ErrorEnum.FileNotFound;
                    };
                    defer self.dir.close();
                    if (path.len > 2) {
                        path = path[2..];
                    }
                    self.dir.setAsCwd() catch |err| {
                        self.stdout.print("fail to read input: {}", .{err}) catch {
                            return ErrorEnum.PrintError;
                        };
                    };
                }
                if (std.fs.cwd().openDir(path, .{})) |open_dir| {
                    self.dir = open_dir;
                    defer self.dir.close();
                    self.dir.setAsCwd() catch |err| {
                        self.stdout.print("fail to read input: {}", .{err}) catch {
                            return ErrorEnum.PrintError;
                        };
                    };
                } else |_| {
                    if (!std.mem.eql(u8, path, "~")) {
                        self.stdout.print("cd: {s}: No such file or directory\n", .{path}) catch {
                            return ErrorEnum.PrintError;
                        };
                    }
                }
            },
            .unknown => {
                _ = findExecutable(self.env_map.get("PATH") orelse "", user_inputs.items[0]) catch {
                    self.stdout.print("{s}: not found\n", .{command_str}) catch {
                        return ErrorEnum.PrintError;
                    };
                    return ErrorEnum.FileNotFound;
                };
                var cmd = std.process.Child.init(user_inputs.items, self.pa);
                _ = cmd.spawnAndWait() catch {
                    return ErrorEnum.ExecuteError;
                };
            },
        }
    }
};

pub fn init() !Shell {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const gpa = general_purpose_allocator.allocator();
    const allocator = std.heap.page_allocator;
    const env_map = std.process.getEnvMap(allocator) catch {
        return ErrorEnum.Unexpected;
    };
    const shell = Shell{ .stdin = stdin, .stdout = stdout, .gpa = gpa, .env_map = env_map, .dir = undefined, .pa = allocator };
    return shell;
}

pub fn findExecutable(path_var: []const u8, arg: []const u8) ErrorEnum![]const u8 {
    var parsed_dir = std.mem.splitScalar(u8, path_var, ':');
    const allocator = std.heap.page_allocator;
    while (parsed_dir.next()) |dir_str| {
        const full_path = std.fs.path.join(allocator, &[_][]const u8{ dir_str, arg }) catch {
            return ErrorEnum.FileNotFound;
        };
        defer allocator.free(full_path);
        const file = std.fs.openFileAbsolute(full_path, .{ .mode = .read_only }) catch {
            continue;
        };
        defer file.close();
        return dir_str;
    }
    return ErrorEnum.FileNotFound;
}

fn parseStrToEnum(str: []const u8) DefaultCommand {
    if (std.meta.stringToEnum(DefaultCommand, str)) |parsedCommand| {
        return parsedCommand;
    } else {
        return DefaultCommand.unknown;
    }
}
