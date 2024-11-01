const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"tardy/aio/epoll");

const Completion = @import("completion.zig").Completion;
const Result = @import("completion.zig").Result;
const Stat = @import("completion.zig").Stat;
const Timespec = @import("timespec.zig").Timespec;

const AsyncIO = @import("lib.zig").AsyncIO;
const AsyncIOOptions = @import("lib.zig").AsyncIOOptions;
const Job = @import("job.zig").Job;
const Pool = @import("../core/pool.zig").Pool;

pub const AsyncEpoll = struct {
    epoll_fd: std.posix.fd_t,
    wake_event_fd: std.posix.fd_t,
    events: []std.os.linux.epoll_event,
    jobs: Pool(Job),
    // This is for jobs that are not supported and need
    // to be blocking.
    blocking: std.ArrayList(*Job),

    pub fn init(allocator: std.mem.Allocator, options: AsyncIOOptions) !AsyncEpoll {
        const size = options.size_aio_jobs_max + 1;
        const epoll_fd = try std.posix.epoll_create1(0);
        assert(epoll_fd > -1);

        const wake_event_fd: std.posix.fd_t = @intCast(std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC));

        const events = try allocator.alloc(std.os.linux.epoll_event, options.size_aio_reap_max);
        var jobs = try Pool(Job).init(allocator, size, null, null);
        const blocking = std.ArrayList(*Job).init(allocator);

        // Queue the wake task.

        {
            const borrowed = jobs.borrow_assume_unset(0);
            borrowed.item.* = .{
                .index = borrowed.index,
                .type = .wake,
                .task = undefined,
            };

            var event: std.os.linux.epoll_event = .{
                .events = std.os.linux.EPOLL.IN,
                .data = .{ .u64 = borrowed.index },
            };

            try std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, wake_event_fd, &event);
        }

        return AsyncEpoll{
            .epoll_fd = epoll_fd,
            .wake_event_fd = wake_event_fd,
            .events = events,
            .jobs = jobs,
            .blocking = blocking,
        };
    }

    pub fn deinit(self: *AsyncIO, allocator: std.mem.Allocator) void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        std.posix.close(epoll.epoll_fd);
        allocator.free(epoll.events);
        epoll.jobs.deinit(null, null);
        epoll.blocking.deinit();
        std.posix.close(epoll.wake_event_fd);
    }

    pub fn queue_timer(
        self: *AsyncIO,
        task: usize,
        timespec: Timespec,
    ) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        const borrowed = try epoll.jobs.borrow_hint(task);

        const timer_fd_usize = std.os.linux.timerfd_create(std.os.linux.CLOCK.MONOTONIC, .{ .NONBLOCK = true });
        const timer_fd: i32 = @intCast(timer_fd_usize);
        const ktimerspec: std.os.linux.itimerspec = .{
            .it_value = .{
                .tv_sec = @intCast(timespec.seconds),
                .tv_nsec = @intCast(timespec.nanos),
            },
            .it_interval = .{
                .tv_sec = 0,
                .tv_nsec = 0,
            },
        };

        _ = std.os.linux.timerfd_settime(timer_fd, .{}, &ktimerspec, null);

        borrowed.item.* = .{
            .index = borrowed.index,
            .type = .{ .timer = .{ .fd = timer_fd } },
            .task = task,
        };

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .u64 = borrowed.index },
        };

        try epoll.add_fd(timer_fd, &event);
    }

    pub fn queue_open(
        self: *AsyncIO,
        task: usize,
        path: [:0]const u8,
    ) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        const borrowed = try epoll.jobs.borrow_hint(task);
        borrowed.item.* = .{
            .index = borrowed.index,
            .type = .{ .open = path },
            .task = task,
        };

        try epoll.blocking.append(borrowed.item);
    }

    pub fn queue_stat(
        self: *AsyncIO,
        task: usize,
        fd: std.posix.fd_t,
    ) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        const borrowed = try epoll.jobs.borrow_hint(task);
        borrowed.item.* = .{
            .index = borrowed.index,
            .type = .{ .stat = fd },
            .task = task,
        };

        try epoll.blocking.append(borrowed.item);
    }

    pub fn queue_read(
        self: *AsyncIO,
        task: usize,
        fd: std.posix.fd_t,
        buffer: []u8,
        offset: usize,
    ) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        const borrowed = try epoll.jobs.borrow_hint(task);
        borrowed.item.* = .{
            .index = borrowed.index,
            .type = .{
                .read = .{
                    .fd = fd,
                    .buffer = buffer,
                    .offset = offset,
                },
            },
            .task = task,
        };

        try epoll.blocking.append(borrowed.item);
    }

    pub fn queue_write(
        self: *AsyncIO,
        task: usize,
        fd: std.posix.fd_t,
        buffer: []const u8,
        offset: usize,
    ) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        const borrowed = try epoll.jobs.borrow_hint(task);
        borrowed.item.* = .{
            .index = borrowed.index,
            .type = .{
                .write = .{
                    .fd = fd,
                    .buffer = buffer,
                    .offset = offset,
                },
            },
            .task = task,
        };

        try epoll.blocking.append(borrowed.item);
    }

    pub fn queue_close(
        self: *AsyncIO,
        task: usize,
        fd: std.posix.fd_t,
    ) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        const borrowed = try epoll.jobs.borrow_hint(task);
        borrowed.item.* = .{
            .index = borrowed.index,
            .type = .{ .close = fd },
            .task = task,
        };

        epoll.remove_fd(fd) catch {};
        try epoll.blocking.append(borrowed.item);
    }

    pub fn queue_accept(
        self: *AsyncIO,
        task: usize,
        socket: std.posix.socket_t,
    ) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        const borrowed = try epoll.jobs.borrow_hint(task);
        borrowed.item.* = .{
            .index = borrowed.index,
            .type = .{ .accept = socket },
            .task = task,
        };

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .u64 = borrowed.index },
        };

        try epoll.add_or_mod_fd(socket, &event);
    }

    pub fn queue_connect(
        self: *AsyncIO,
        task: usize,
        socket: std.posix.socket_t,
        host: []const u8,
        port: u16,
    ) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        const borrowed = try epoll.jobs.borrow_hint(task);
        const addr = try std.net.Address.parseIp(host, port);

        borrowed.item.* = .{
            .index = borrowed.index,
            .type = .{
                .connect = .{
                    .socket = socket,
                    .addr = addr.any,
                },
            },
            .task = task,
        };

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.OUT,
            .data = .{ .u64 = borrowed.index },
        };

        try epoll.add_or_mod_fd(socket, &event);
    }

    pub fn queue_recv(
        self: *AsyncIO,
        task: usize,
        socket: std.posix.socket_t,
        buffer: []u8,
    ) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        const borrowed = try epoll.jobs.borrow_hint(task);
        borrowed.item.* = .{
            .index = borrowed.index,
            .type = .{
                .recv = .{
                    .socket = socket,
                    .buffer = buffer,
                },
            },
            .task = task,
        };

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .u64 = borrowed.index },
        };

        try epoll.add_or_mod_fd(socket, &event);
    }

    pub fn queue_send(
        self: *AsyncIO,
        task: usize,
        socket: std.posix.socket_t,
        buffer: []const u8,
    ) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        const borrowed = try epoll.jobs.borrow_hint(task);
        borrowed.item.* = .{
            .index = borrowed.index,
            .type = .{
                .send = .{
                    .socket = socket,
                    .buffer = buffer,
                },
            },
            .task = task,
        };

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.OUT,
            .data = .{ .u64 = borrowed.index },
        };

        try epoll.add_or_mod_fd(socket, &event);
    }

    fn add_or_mod_fd(self: *AsyncEpoll, fd: std.posix.fd_t, event: *std.os.linux.epoll_event) !void {
        self.add_fd(fd, event) catch |e| {
            if (e == error.FileDescriptorAlreadyPresentInSet) {
                try self.mod_fd(fd, event);
            } else return e;
        };
    }

    fn add_fd(self: *AsyncEpoll, fd: std.posix.fd_t, event: *std.os.linux.epoll_event) !void {
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, event);
    }

    fn mod_fd(self: *AsyncEpoll, fd: std.posix.fd_t, event: *std.os.linux.epoll_event) !void {
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, event);
    }

    fn remove_fd(self: *AsyncEpoll, fd: std.posix.fd_t) !void {
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
    }

    pub fn wake(self: *AsyncIO) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));

        const bytes: []const u8 = "00000000";
        var i: usize = 0;
        while (i < bytes.len) {
            i += try std.posix.write(epoll.wake_event_fd, bytes);
        }
    }

    pub fn submit(self: *AsyncIO) !void {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        _ = epoll;
    }

    pub fn reap(self: *AsyncIO, wait: bool) ![]Completion {
        const epoll: *AsyncEpoll = @ptrCast(@alignCast(self.runner));
        var reaped: usize = 0;
        var first_run: bool = true;

        const busy_wait: bool = !wait or epoll.blocking.items.len > 0;
        log.debug("busy wait? {}", .{busy_wait});

        while ((reaped < 1 and wait) or first_run) {
            blocking_loop: for (0..epoll.blocking.items.len) |_| {
                const job = epoll.blocking.popOrNull() orelse break;
                assert(epoll.jobs.dirty.isSet(job.index));

                if (self.completions.len - reaped == 0) break;

                var job_complete = true;
                defer if (job_complete) {
                    epoll.jobs.release(job.index);
                } else {
                    // if not done, readd to blocking list.
                    epoll.blocking.appendAssumeCapacity(job);
                };

                const result: Result = result: {
                    switch (job.type) {
                        else => unreachable,
                        .open => |path| {
                            const opened = std.posix.openatZ(std.posix.AT.FDCWD, path, .{}, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => {
                                        job_complete = false;
                                        continue :blocking_loop;
                                    },
                                    else => {
                                        log.debug("open failed: {}", .{e});
                                        break :result .{ .fd = -1 };
                                    },
                                }
                            };

                            break :result .{ .fd = opened };
                        },
                        .stat => |fd| {
                            const fstat = std.posix.fstat(fd) catch |e| {
                                log.err("stat failed: {}", .{e});
                                unreachable;
                            };

                            const stat: Stat = .{
                                .size = @intCast(fstat.size),
                                .mode = @intCast(fstat.mode),
                                .accessed = .{
                                    .seconds = @intCast(fstat.atim.tv_sec),
                                    .nanos = @intCast(fstat.atim.tv_nsec),
                                },
                                .modified = .{
                                    .seconds = @intCast(fstat.atim.tv_sec),
                                    .nanos = @intCast(fstat.atim.tv_nsec),
                                },
                                .changed = .{
                                    .seconds = @intCast(fstat.atim.tv_sec),
                                    .nanos = @intCast(fstat.atim.tv_nsec),
                                },
                            };

                            break :result .{ .stat = stat };
                        },
                        .read => |inner| {
                            const bytes_read = read: {
                                break :read std.posix.pread(inner.fd, inner.buffer, inner.offset) catch |e| {
                                    switch (e) {
                                        error.WouldBlock => unreachable,
                                        error.Unseekable => {
                                            break :read std.posix.read(inner.fd, inner.buffer) catch |re| {
                                                switch (re) {
                                                    error.WouldBlock => {
                                                        job_complete = false;
                                                        continue :blocking_loop;
                                                    },
                                                    else => {
                                                        log.debug("read failed: {}", .{e});
                                                        break :result .{ .value = -1 };
                                                    },
                                                }
                                            };
                                        },
                                        else => {
                                            log.debug("pread failed: {}", .{e});
                                            break :result .{ .value = -1 };
                                        },
                                    }
                                };
                            };

                            break :result .{ .value = @intCast(bytes_read) };
                        },
                        .write => |inner| {
                            const bytes_written = write: {
                                break :write std.posix.pwrite(inner.fd, inner.buffer, inner.offset) catch |e| {
                                    switch (e) {
                                        error.WouldBlock => unreachable,
                                        error.Unseekable => {
                                            break :write std.posix.write(inner.fd, inner.buffer) catch |we| {
                                                switch (we) {
                                                    error.WouldBlock => {
                                                        job_complete = false;
                                                        continue :blocking_loop;
                                                    },
                                                    else => {
                                                        log.debug("write failed: {}", .{e});
                                                        break :result .{ .value = -1 };
                                                    },
                                                }
                                            };
                                        },
                                        else => {
                                            log.debug("pwrite failed: {}", .{e});
                                            break :result .{ .value = -1 };
                                        },
                                    }
                                };
                            };

                            break :result .{ .value = @intCast(bytes_written) };
                        },
                        .close => |handle| {
                            std.posix.close(handle);
                            break :result .none;
                        },
                    }
                };

                self.completions[reaped] = .{
                    .result = result,
                    .task = job.task,
                };

                reaped += 1;
            }

            const timeout: i32 = if (busy_wait or reaped > 0) 0 else -1;

            // Handle all of the epoll I/O
            const epoll_events = std.posix.epoll_wait(epoll.epoll_fd, epoll.events[0..], timeout);
            epoll_loop: for (epoll.events[0..epoll_events]) |event| {
                const job_index = event.data.u64;
                assert(epoll.jobs.dirty.isSet(job_index));

                var job_complete = true;
                defer if (job_complete) epoll.jobs.release(job_index);
                const job = epoll.jobs.items[job_index];

                const result: Result = result: {
                    switch (job.type) {
                        else => unreachable,
                        .wake => {
                            // this keeps it in the job queue and we pretty
                            // much never want to remove this fd.
                            job_complete = false;
                            var buffer: [8]u8 = undefined;
                            _ = std.posix.read(epoll.wake_event_fd, buffer[0..]) catch |e| {
                                switch (e) {
                                    error.WouldBlock => unreachable,
                                    else => {
                                        log.err("wake failed: {}", .{e});
                                        unreachable;
                                    },
                                }
                            };

                            break :result .wake;
                        },
                        .timer => |inner| {
                            const timer_fd = inner.fd;
                            defer epoll.remove_fd(timer_fd) catch unreachable;
                            assert(event.events & std.os.linux.EPOLL.IN != 0);

                            var buffer: [8]u8 = undefined;
                            _ = std.posix.read(timer_fd, buffer[0..]) catch |e| {
                                switch (e) {
                                    error.WouldBlock => unreachable,
                                    else => {
                                        log.debug("timer failed: {}", .{e});
                                        break :result .{ .value = -1 };
                                    },
                                }
                            };

                            break :result .none;
                        },
                        .accept => |socket| {
                            assert(event.events & std.os.linux.EPOLL.IN != 0);
                            const accepted = std.posix.accept(socket, null, null, 0) catch |e| {
                                switch (e) {
                                    // This is only allowed here because
                                    // multiple threads are sitting on accept.
                                    // Any other case is unreachable.
                                    error.WouldBlock => {
                                        job_complete = false;
                                        continue :epoll_loop;
                                    },
                                    else => {
                                        log.debug("accept failed: {}", .{e});
                                        try epoll.remove_fd(socket);
                                        break :result .{ .socket = -1 };
                                    },
                                }
                            };

                            try epoll.remove_fd(socket);
                            break :result .{ .socket = accepted };
                        },
                        .connect => |inner| {
                            assert(event.events & std.os.linux.EPOLL.OUT != 0);
                            const addr_len: std.posix.socklen_t = switch (inner.addr.family) {
                                std.posix.AF.INET => @sizeOf(std.posix.sockaddr.in),
                                std.posix.AF.INET6 => @sizeOf(std.posix.sockaddr.in6),
                                std.posix.AF.UNIX => @sizeOf(std.posix.sockaddr.un),
                                else => @panic("Unsupported!"),
                            };

                            std.posix.connect(inner.socket, &inner.addr, addr_len) catch |e| {
                                switch (e) {
                                    error.WouldBlock => unreachable,
                                    else => {
                                        log.debug("connect failed: {}", .{e});
                                        try epoll.remove_fd(inner.socket);
                                        break :result .{ .value = -1 };
                                    },
                                }
                            };

                            break :result .{ .value = 1 };
                        },
                        .recv => |inner| {
                            assert(event.events & std.os.linux.EPOLL.IN != 0);
                            const bytes_read = std.posix.recv(inner.socket, inner.buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => {
                                        job_complete = false;
                                        continue :epoll_loop;
                                    },
                                    error.ConnectionResetByPeer => {
                                        try epoll.remove_fd(inner.socket);
                                        break :result .{ .value = 0 };
                                    },
                                    else => {
                                        log.debug("recv failed: {}", .{e});
                                        try epoll.remove_fd(inner.socket);
                                        break :result .{ .value = -1 };
                                    },
                                }
                            };

                            break :result .{ .value = @intCast(bytes_read) };
                        },
                        .send => |inner| {
                            assert(event.events & std.os.linux.EPOLL.OUT != 0);
                            const bytes_sent = std.posix.send(inner.socket, inner.buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => {
                                        job_complete = false;
                                        continue :epoll_loop;
                                    },
                                    error.ConnectionResetByPeer => {
                                        try epoll.remove_fd(inner.socket);
                                        break :result .{ .value = 0 };
                                    },
                                    else => {
                                        log.debug("send failed: {}", .{e});
                                        try epoll.remove_fd(inner.socket);
                                        break :result .{ .value = -1 };
                                    },
                                }
                            };

                            break :result .{ .value = @intCast(bytes_sent) };
                        },
                    }
                };

                self.completions[reaped] = .{
                    .result = result,
                    .task = job.task,
                };

                reaped += 1;
            }

            first_run = false;
        }

        return self.completions[0..reaped];
    }

    pub fn to_async(self: *AsyncEpoll) AsyncIO {
        return AsyncIO{
            .runner = self,
            ._deinit = deinit,
            ._queue_timer = queue_timer,
            ._queue_open = queue_open,
            ._queue_stat = queue_stat,
            ._queue_read = queue_read,
            ._queue_write = queue_write,
            ._queue_close = queue_close,
            ._queue_accept = queue_accept,
            ._queue_connect = queue_connect,
            ._queue_recv = queue_recv,
            ._queue_send = queue_send,
            ._wake = wake,
            ._submit = submit,
            ._reap = reap,
        };
    }
};
