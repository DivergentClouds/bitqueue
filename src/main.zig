const std = @import("std");

const Command = enum(u8) {
    one = '1',
    zero = '0',
    call = '>',
    ret = '<',
    ret_jmp = '^',
    call_current = '"',
    define_fn = ':',
    anon_fn = '\'',
    conditional = '?',
    block_start = '(',
    block_end = ')',
    input = ',',
    output = '.',
    comment = ';',
};

const Instruction = struct {
    command: ?Command, // If an identifier is reached, this does not change, only null if error
    identifier: ?u64, // Hash of identifier name, null if no current identifier
};

const Identifier = enum {
    call, // after `>`
    define, // after `:`
    none, // otherwise
};

const Level = enum {
    conditional,
    function,
    block,
};

const Direction = enum {
    forward,
    backward,
};

pub fn main() !void {
    const stderr = std.io.getStdErr();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        try stderr.writeAll("Wrong number of arguments\n\n");
        try stderr.writeAll("Usage:\nbitqueue <program file>\n");
        return error.BadArgs;
    }

    const code_file = try std.fs.cwd().openFile(args[1], .{});
    defer code_file.close();

    const code = try code_file.readToEndAlloc(allocator, (try code_file.metadata()).size());
    defer allocator.free(code);

    try interpret(code, allocator);
}

fn interpret(code: []u8, allocator: std.mem.Allocator) !void {
    const levels = try allocator.alloc(Level, 256);
    defer allocator.free(levels);

    var depth: usize = 0; // number of levels currently being used

    var line: usize = 1;
    var column: usize = 0; // incremented on first call of traverseCode()
    var comment: bool = false;
    var instruction_address: usize = 0;

    var instruction: Instruction = Instruction{
        .command = null,
        .identifier = null,
    };

    var queue_start: usize = 0;
    var queue_end: usize = 0;
    var queue_alloc_size: usize = 1024 * 8; // 1 KiB of bits

    var queue = try std.DynamicBitSet.initFull(allocator, queue_alloc_size);
    defer queue.deinit();

    var running = true;

    while (running) {
        instruction = traverseCode(code, &instruction_address, instruction, &line, &column, .forward, &comment, allocator) orelse return;
        switch (instruction.command orelse {
            try printError(error.UnexpectedIdentifier, line, column, null); // TODO: Make print interned identifier name
            return;
        }) {
            .one => {
                try enqueue(&queue, &queue_end, 1, &queue_alloc_size);
            },
            .zero => {
                try enqueue(&queue, &queue_end, 0, &queue_alloc_size);
            },
            .call => {
                try addLevel(levels, &depth, .function, allocator);
            },
            .ret => {},
            .ret_jmp => {},
            .call_current => {},
            .define_fn => {},
            .anon_fn => {},
            .conditional => {},
            .block_start => {},
            .block_end => {},
            .input => {},
            .output => {},
            .comment => {
                comment = true;
            },
        }
    }
    _ = queue_start;
}

fn enqueue(queue: *std.bit_set.DynamicBitSet, index: *usize, value: u1, size: *usize) !void {
    index.* += 1;

    if (index.* == size.*) {
        size.* += 1024;
        try queue.*.resize(size.*, false);
    }

    queue.*.setValue(index.*, value == 1);
}

fn addLevel(levels: []Level, depth: *usize, value: Level, allocator: std.mem.Allocator) !void {
    depth.* += 1;

    if (depth.* == levels.len) {
        depth.* += 256;
        if (allocator.resize(levels, depth.*) == false) return error.ResizeFailed;
    }

    levels[depth.*] = value;
}

// TODO
fn removeLevel(code: []u8, address: *usize, levels: []Level, depth: *usize) ?Level {
    _ = code;
    _ = address;
    _ = levels;
    _ = depth;
    return null;
}

fn traverseCode(
    code: []u8,
    address: *usize,
    old_instruction: Instruction,
    line: *usize,
    column: *usize,
    direction: Direction,
    comment: *bool,
    allocator: std.mem.Allocator,
) ?Instruction {
    if (address.* == code.len) return null;

    const char = code[address.*];

    var instruction: Instruction = undefined;
    instruction.identifier = null;

    if (direction == .forward) {
        if (char == '\n') {
            column.* = 0; // will be incremented
            line.* += 1;
            comment.* = false;
        } else {
            column.* += 1;
        }
    } // errors should only appear when moving forward because all data before will have already
    //   been scanned, therefore line and column will not be needed

    if (direction == .forward) {
        address.* += 1;
        if (comment.*) {
            return traverseCode(code, address, old_instruction, line, column, direction, comment, allocator);
        }
        if (std.ascii.isAlphabetic(char) or char == '_') {
            instruction.identifier = parseIdentifier(code, address);
        } else if (std.ascii.isWhitespace(char)) {
            return traverseCode(code, address, old_instruction, line, column, direction, comment, allocator);
        }
    } else {
        address.* -|= 1;
    }

    if (instruction.identifier == null) {
        instruction.command = std.meta.intToEnum(Command, char) catch {
            // error unions cannot be tail-call optimized, which this function needs
            printError(error.InvalidCharacter, line.*, column.*, char) catch {};
            return null;
        };
    } else {
        instruction.command = old_instruction.command;
    }

    return instruction;
}

fn parseIdentifier(code: []u8, address: *usize) u64 {
    const begin = address.* - 1;
    var end = address.*; // slice syntax is non-inclusive on the right side

    while (address.* < code.len) : (address.* += 1) {
        if (std.ascii.isAlphanumeric(code[address.*]) or code[address.*] == '_') {
            end += 1;
        } else {
            break;
        }
    }

    // incredibly small chance of collision
    // TODO: change this to string interning later
    return std.hash.Murmur3_32.hash(code[begin..end]);
}

fn printError(err: anyerror, line: usize, column: usize, char: ?u8) !void {
    var stderr = std.io.getStdErr();
    try stderr.writer().print("Error on line: {d}, column: {d}\n", .{ line, column });

    switch (err) {
        error.InvalidCharacter => try stderr.writer().print("Invalid Character '{c}'\n", .{char.?}),
        error.UnexpectedIdentifier => try stderr.writer().print("Unexpected Identifier\n", .{}),
        else => try stderr.writeAll("Unknown Error\n"),
    }

    return;
}
