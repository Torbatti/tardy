const std = @import("std");
const log = std.log.scoped(.@"tardy/e2e/tcp_chain");
const assert = std.debug.assert;

const Runtime = @import("tardy").Runtime;

const Socket = @import("tardy").Socket;

const OpenFileResult = @import("tardy").OpenFileResult;
const ReadResult = @import("tardy").ReadResult;
const WriteResult = @import("tardy").WriteResult;
const DeleteResult = @import("tardy").DeleteResult;

const TaskFn = @import("tardy").TaskFn;

pub const TcpServerChain = struct {
    const Step = enum {
        accept,
        recv,
        send,
        close,
    };

    allocator: std.mem.Allocator,
    socket: ?Socket = null,
    steps: []Step,
    index: usize = 0,
    buffer: []u8,

    pub fn next_steps(current: Step) []const Step {
        switch (current) {
            .accept, .recv, .send => return &.{ .recv, .send, .close },
            .close => return &.{},
        }
    }

    pub fn validate_chain(chain: []const Step) bool {
        if (chain.len < 2) return false;
        if (chain[0] != .accept) return false;
        if (chain[chain.len - 1] != .close) return false;

        chain: for (chain[0 .. chain.len - 1], chain[1..]) |prev, curr| {
            const steps = next_steps(prev);
            for (steps[0..]) |step| if (curr == step) continue :chain;
            return false;
        }

        return true;
    }

    pub fn generate_random_chain(allocator: std.mem.Allocator, seed: u64) ![]Step {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var list = try std.ArrayListUnmanaged(Step).initCapacity(allocator, 0);
        defer list.deinit(allocator);
        try list.append(allocator, .accept);

        while (true) {
            const potentials = next_steps(list.getLast());
            if (potentials.len == 0) break;
            const potential = rand.intRangeLessThan(usize, 0, potentials.len);
            try list.append(allocator, potentials[potential]);
        }

        return try list.toOwnedSlice(allocator);
    }

    pub fn derive_client_chain(self: *const TcpServerChain) !TcpClientChain {
        assert(self.steps.len > 0);

        const client_steps = try self.allocator.alloc(TcpClientChain.Step, self.steps.len);
        errdefer self.allocator.free(client_steps);

        for (self.steps, 0..) |step, i| {
            switch (step) {
                .accept => client_steps[i] = .connect,
                .recv => client_steps[i] = .send,
                .send => client_steps[i] = .recv,
                .close => client_steps[i] = .close,
            }
        }

        const buffer = try self.allocator.alloc(u8, self.buffer.len);
        errdefer self.allocator.free(buffer);

        return .{
            .allocator = self.allocator,
            .steps = client_steps,
            .buffer = buffer,
        };
    }

    // Path is expected to remain valid.
    pub fn init(allocator: std.mem.Allocator, chain: []const Step, buffer_size: usize) !TcpServerChain {
        assert(chain.len > 0);

        const chain_dupe = try allocator.dupe(Step, chain);
        errdefer allocator.free(chain_dupe);
        assert(validate_chain(chain));

        const buffer = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(buffer);

        return .{
            .allocator = allocator,
            .steps = chain_dupe,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *const TcpServerChain) void {
        defer self.allocator.free(self.steps);
        defer self.allocator.free(self.buffer);
    }

    pub fn chain_frame(chain: *TcpServerChain, rt: *Runtime, counter: *usize, server_socket: Socket) !void {
        defer rt.allocator.destroy(chain);
        defer chain.deinit();

        chain: while (chain.index < chain.steps.len) : (chain.index += 1) {
            switch (chain.steps[chain.index]) {
                .accept => {
                    const socket = try server_socket.accept().resolve(rt);
                    chain.socket = socket;
                },
                .recv => {
                    const length = chain.socket.?.recv(chain.buffer).resolve(rt) catch |e| switch (e) {
                        error.Closed => break :chain,
                        else => return e,
                    };

                    for (chain.buffer[0..length]) |item| assert(item == 123);
                },
                .send => {
                    for (chain.buffer[0..]) |*item| item.* = 123;
                    _ = try chain.socket.?.send_all(chain.buffer).resolve(rt);
                },
                .close => try chain.socket.?.close().resolve(rt),
            }
        }
        counter.* -= 1;

        log.warn("counter={d}", .{counter.*});
        if (counter.* == 0) {
            log.debug("closing main accept socket", .{});
            try server_socket.close().resolve(rt);
        }
    }
};

pub const TcpClientChain = struct {
    const Step = enum {
        connect,
        recv,
        send,
        close,
    };

    allocator: std.mem.Allocator,
    steps: []Step,
    index: usize = 0,
    buffer: []u8,

    pub fn deinit(self: *const TcpClientChain) void {
        defer self.allocator.free(self.steps);
        defer self.allocator.free(self.buffer);
    }

    pub fn chain_frame(chain: *TcpClientChain, rt: *Runtime, counter: *usize, port: u16) !void {
        defer rt.allocator.destroy(chain);
        defer chain.deinit();

        var socket: ?Socket = null;

        chain: while (chain.index < chain.steps.len) : (chain.index += 1) {
            switch (chain.steps[chain.index]) {
                .connect => {
                    // must create a new socket on connect since close will shut it down :(
                    socket = try Socket.init(.{ .tcp = .{ .host = "127.0.0.1", .port = port } });
                    _ = try socket.?.connect().resolve(rt);
                },
                .recv => {
                    const length = socket.?.recv(chain.buffer).resolve(rt) catch |e| switch (e) {
                        error.Closed => break :chain,
                        else => return e,
                    };

                    for (chain.buffer[0..length]) |item| assert(item == 123);
                },
                .send => {
                    for (chain.buffer[0..]) |*item| item.* = 123;
                    _ = try socket.?.send_all(chain.buffer).resolve(rt);
                },
                .close => try socket.?.close().resolve(rt),
            }
        }
        counter.* -= 1;

        log.warn("counter={d}", .{counter.*});
        if (counter.* == 0) {
            log.debug("tcp client chain done!", .{});
        }
    }
};

const testing = std.testing;

test "TcpServerChain: Proper Chain" {
    const chain: []const TcpServerChain.Step = &.{
        .accept,
        .recv,
        .send,
        .close,
    };

    try testing.expect(TcpServerChain.validate_chain(chain));
}

test "TcpServerChain: Validate Random Chain" {
    // Actually generates and tests a random TcpServerChain :)
    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));

    const chain = try TcpServerChain.generate_random_chain(testing.allocator, seed);
    defer testing.allocator.free(chain);

    errdefer {
        std.debug.print("failed seed: {d}\n", .{seed});
        for (chain) |item| {
            std.debug.print("action={s}\n", .{@tagName(item)});
        }
    }

    try testing.expect(TcpServerChain.validate_chain(chain));
}
