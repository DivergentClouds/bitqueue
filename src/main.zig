const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    // set up args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        printUsage(args[0], "Wrong number of arguments") catch {};
        return error.BadArgCount;
    }

    const code_file = try std.fs.cwd().openFile(args[1], .{});
    defer code_file.close();

    try interpret(code_file, allocator);
}

const Command = enum(u8) {
    one = '1',
    zero = '0',
    call = '>',
    ret = '<',
    ret_up = '^',
    ret_2 = '*',
    call_current = '"',
    define = ':',
    call_anon = '\'',
    conditional = '?',
    start_block = '(',
    end_block = ')',
    input = ',',
    output = '.',
    dump_state = '#',
    comment = ';',
    _,
};

const Function = struct {
    /// start of body
    entry: usize,
    /// after body
    exit: usize,
};

const FunctionCall = struct {
    function: Function,
    return_address: usize,
};

fn interpret(code_file: std.fs.File, backing_allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var queue = std.ArrayList(u1).init(allocator);
    defer queue.deinit();

    var call_stack = std.ArrayList(FunctionCall).init(allocator);
    defer call_stack.deinit();

    var anon_function_map = std.AutoHashMap(
        usize,
        Function,
    ).init(allocator);
    defer anon_function_map.deinit();

    var named_function_map = std.StringHashMap(Function).init(allocator);
    defer named_function_map.deinit();

    try parseNamedFunctions(
        code_file,
        &named_function_map,
        allocator,
    );

    try parseAnonFunctions(
        code_file,
        &anon_function_map,
    );

    const stdout = std.io.getStdOut().writer();

    const code_reader = code_file.reader().any();
    while (readByteNoWhitespace(code_reader)) |byte| {
        const command: Command = @enumFromInt(byte);

        if (call_stack.getLastOrNull()) |current_function| {
            const exit_address = current_function.function.exit;
            if (try code_file.getPos() > exit_address) {
                try returnFromFunction(code_file, &call_stack);
                continue;
            }
        }

        switch (command) {
            .one => {
                try queue.append(1);
            },
            .zero => {
                try queue.append(0);
            },
            .call => {
                const function_name = try readFunctionName(code_file, backing_allocator);
                defer backing_allocator.free(function_name);

                const function = named_function_map.get(function_name) orelse
                    return error.AttemptToCallUndefinedFunction;

                try call_stack.append(FunctionCall{
                    .function = function,
                    .return_address = try code_file.getPos(),
                });

                try code_file.seekTo(function.entry);
            },
            .ret => {
                try returnFromFunction(code_file, &call_stack);
            },
            .ret_up => {
                try returnFromFunction(code_file, &call_stack);

                const start = if (call_stack.getLastOrNull()) |current_function|
                    current_function.function.entry
                else
                    0;

                try code_file.seekTo(start);
            },
            .ret_2 => {
                _ = call_stack.popOrNull();
                try returnFromFunction(code_file, &call_stack);
            },
            .call_current => {
                // TODO: add tailcall optimization?
                const current_function_call = call_stack.getLastOrNull() orelse
                    return error.AttemptToCallFileAsFunction;

                try call_stack.append(FunctionCall{
                    .function = current_function_call.function,
                    .return_address = try code_file.getPos() + 1,
                });

                try code_file.seekTo(current_function_call.function.entry);
            },
            .define => {
                try skipFunctionName(code_file);
                try skipBody(code_file);
            },
            .call_anon => {
                const anon_function = anon_function_map.get(try code_file.getPos()).?;
                try call_stack.append(FunctionCall{
                    .function = anon_function,
                    .return_address = anon_function.exit,
                });
            },
            .conditional => {
                if (queue.items.len == 0) {
                    return;
                }
                if (queue.orderedRemove(0) == 0) {
                    try skipBody(code_file);
                }
            },
            .start_block, .end_block => {},
            .input => {
                const stdin = std.io.getStdIn().reader();
                var input_byte: u8 = stdin.readByte() catch continue;
                var bit: u1 = undefined;

                for (0..8) |_| {
                    input_byte, bit = @shlWithOverflow(input_byte, @as(u3, @intCast(1)));
                    try queue.append(bit);
                }
            },
            .output => {
                var output_byte: u8 = 0;

                for (0..8) |_| {
                    output_byte >>= 1;
                    output_byte |= @as(u8, queue.popOrNull() orelse return) << 7;
                }
                try stdout.writeByte(output_byte);
            },
            .dump_state => {
                for (queue.items) |bit| {
                    try stdout.print("{d} ", .{bit});
                }
                try stdout.writeByte('\n');
            },
            .comment => skipComments(code_reader),
            else => {
                return error.UnknownCommand;
            },
        }
    }
}

fn returnFromFunction(
    code_file: std.fs.File,
    call_stack: *std.ArrayList(FunctionCall),
) !void {
    const from: ?FunctionCall = call_stack.popOrNull();
    const return_address = if (from) |call|
        call.return_address
    else
        try code_file.getEndPos();

    try code_file.seekTo(return_address);
}

//// Caller owns any returned function names in map
fn parseNamedFunctions(
    code_file: std.fs.File,
    named_function_map: *std.StringHashMap(Function),
    allocator: std.mem.Allocator,
) !void {
    var depth: usize = 0;
    const code_reader = code_file.reader().any();
    defer code_file.seekTo(0) catch
        std.debug.panic("could not reset file position after parsing functions", .{});

    while (readByteNoWhitespace(code_reader)) |byte| {
        const command: Command = @enumFromInt(byte);
        switch (command) {
            .define => {
                if (depth != 0) return error.FunctionDefinitionInBody;

                const name = try readFunctionName(code_file, allocator);
                try named_function_map.put(
                    name,
                    try findFunctionBounds(code_file),
                );
            },
            .comment => {
                skipComments(code_reader);
            },
            .start_block => {
                depth += 1;
            },
            .end_block => {
                if (depth == 0) return error.UnopenedBlock;
                depth -= 1;
            },
            else => {},
        }
    }
}
// Caller owns any returned function names in map
fn parseAnonFunctions(
    code_file: std.fs.File,
    anon_function_map: *std.AutoHashMap(usize, Function),
) !void {
    var code_reader = code_file.reader();
    defer code_file.seekTo(0) catch
        std.debug.panic("could not reset file position after parsing functions", .{});

    while (readByteNoWhitespace(code_reader.any())) |byte| {
        const command: Command = @enumFromInt(byte);
        switch (command) {
            .comment => {
                skipComments(code_reader.any());
            },
            .call_anon => {
                const start = try code_file.getPos();
                try anon_function_map.put(
                    start,
                    try findFunctionBounds(code_file),
                );
                try code_file.seekTo(start);
            },
            else => {},
        }
    }
}

fn skipComments(code_reader: std.io.AnyReader) void {
    while (code_reader.readByte() catch null) |byte| {
        if (byte == '\n') break;
    }
}

fn skipFunctionName(code_file: std.fs.File) !void {
    const code_reader = code_file.reader();

    if (readByteNoWhitespace(code_reader.any())) |byte| {
        switch (byte) {
            'a'...'z',
            'A'...'Z',
            '_',
            => {
                while (code_reader.readByte() catch null) |inner_byte| {
                    switch (inner_byte) {
                        'a'...'z',
                        'A'...'Z',
                        '0'...'9',
                        '_',
                        => {
                            continue;
                        },
                        else => {
                            break;
                        },
                    }
                }
            },
            else => {},
        }
    }

    try code_file.seekBy(-1);
}

fn readFunctionName(
    code_file: std.fs.File,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const code_reader = code_file.reader();
    var name = std.ArrayList(u8).init(allocator);
    errdefer name.deinit();

    if (readByteNoWhitespace(code_reader.any())) |initial_byte| {
        switch (initial_byte) {
            'a'...'z',
            'A'...'Z',
            '_',
            => {
                try name.append(initial_byte);

                while (code_reader.readByte() catch null) |next_byte| {
                    if (std.ascii.isWhitespace(next_byte)) break;
                    switch (next_byte) {
                        'a'...'z',
                        'A'...'Z',
                        '0'...'9',
                        '_',
                        => try name.append(next_byte),
                        else => {
                            try code_file.seekBy(-1);
                            return name.toOwnedSlice();
                        },
                    }
                } else return error.NoFunctionFollowingName;
            },
            else => return error.NoFunctionNameGiven,
        }
    } else return error.UnfinishedFunctionName;

    return name.toOwnedSlice();
}

fn findFunctionBounds(code_file: std.fs.File) !Function {
    const entry_address = try code_file.getPos();
    try skipBody(code_file);
    const exit_address: u64 = try code_file.getPos();

    return Function{
        .entry = entry_address,
        .exit = exit_address,
    };
}

fn skipBody(code_file: std.fs.File) !void {
    const code_reader = code_file.reader().any();
    var depth: usize = 0;

    while (readByteNoWhitespace(code_reader)) |byte| {
        const command: Command = @enumFromInt(byte);
        switch (command) {
            .conditional, .call, .call_anon => continue,
            .define => return error.FunctionDefinitionInBody,
            .start_block => depth += 1,
            .end_block => {
                if (depth == 0) return error.UnopenedBlock;
                depth -= 1;
            },
            .comment => skipComments(code_reader),
            else => {
                switch (byte) {
                    'A'...'Z',
                    'a'...'z',
                    '_',
                    => {
                        while (readByteNoWhitespace(code_reader)) |inner_byte| {
                            switch (inner_byte) {
                                'A'...'Z',
                                'a'...'z',
                                '0'...'9',
                                '_',
                                => {},
                                else => {
                                    try code_file.seekBy(-1);
                                    break;
                                },
                            }
                        }
                    },
                    else => {},
                }
            },
        }
        if (depth == 0) break;
    }
}

fn readByteNoWhitespace(reader: std.io.AnyReader) ?u8 {
    while (reader.readByte() catch null) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        return byte;
    } else return null;
}

fn printUsage(arg0: []const u8, error_message: ?[]const u8) !void {
    const writer = if (error_message == null)
        std.io.getStdOut().writer()
    else
        std.io.getStdErr().writer();

    try writer.print(
        \\usage:
        \\{s} <program file>
        \\
    , .{arg0});

    if (error_message) |message| {
        try writer.print("{s}\n", .{message});
    }
}
