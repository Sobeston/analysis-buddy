const std = @import("std");
const analysis = @import("analysis.zig");
const DocumentStore = @import("document_store.zig");
const URI = @import("uri.zig");
const ast = std.zig.ast;

pub fn getFieldAccessType(
    store: *DocumentStore,
    arena: *std.heap.ArenaAllocator,
    handle: *DocumentStore.Handle,
    tokenizer: *std.zig.Tokenizer,
    bound_type_params: *analysis.BoundTypeParams,
) !?analysis.DeclWithHandle {
    var current_type = analysis.TypeWithHandle.typeVal(.{
        .node = &handle.tree.root_node.base,
        .handle = handle,
    });

    var result: ?analysis.DeclWithHandle = null;

    while (true) {
        const tok = tokenizer.next();
        switch (tok.id) {
            .Eof => return result,
            .Identifier => {
                if (try analysis.lookupSymbolGlobal(store, arena, current_type.handle, tokenizer.buffer[tok.loc.start..tok.loc.end], 0)) |child| {
                    current_type = (try child.resolveType(store, arena, bound_type_params)) orelse return null;
                } else return null;
            },
            .Period => {
                const after_period = tokenizer.next();
                switch (after_period.id) {
                    .Eof => return result,
                    .Identifier => {
                        if (result) |child| {
                            current_type = (try child.resolveType(store, arena, bound_type_params)) orelse return null;
                        }
                        current_type = try analysis.resolveFieldAccessLhsType(store, arena, current_type, bound_type_params);

                        var current_type_node = switch (current_type.type.data) {
                            .other => |n| n,
                            else => return null,
                        };

                        if (current_type_node.cast(ast.Node.FnProto)) |func| {
                            if (try analysis.resolveReturnType(store, arena, func, current_type.handle, bound_type_params)) |ret| {
                                current_type = ret;
                                current_type_node = switch (current_type.type.data) {
                                    .other => |n| n,
                                    else => return null,
                                };
                            } else return null;
                        }

                        if (try analysis.lookupSymbolContainer(
                            store,
                            arena,
                            .{ .node = current_type_node, .handle = current_type.handle },
                            tokenizer.buffer[after_period.loc.start..after_period.loc.end],
                            !current_type.type.is_type_val,
                        )) |child| {
                            result = child;
                        } else return null;
                    },
                    else => {
                        return null;
                    },
                }
            },
            else => {
                return null;
            },
        }
    }

    return result;
}

const cache_reload_command = ":reload-cached:";

pub fn main() anyerror!void {
    const gpa = std.heap.page_allocator;

    const reader = std.io.getStdIn().reader();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var args = try std.process.argsWithAllocator(gpa);

    _ = args.skip();
    const lib_path = try args.next(gpa) orelse return error.NoLibPathProvided;
    defer gpa.free(lib_path);
    const resolved_lib_path = try std.fs.path.resolve(gpa, &[_][]const u8{lib_path});
    defer gpa.free(resolved_lib_path);
    std.debug.print("Library path: {}\n", .{resolved_lib_path});
    const lib_uri = try URI.fromPath(gpa, resolved_lib_path);

    var doc_store: DocumentStore = undefined;
    try doc_store.init(gpa, null, "", lib_path);
    defer doc_store.deinit();

    const root_handle = try doc_store.openDocument("file://<ROOT>",
        \\const std = @import("std");
    );

    var timer = try std.time.Timer.start();

    while (true) {
        defer {
            arena.deinit();
            arena.state.buffer_list = .{};
        }

        const line = reader.readUntilDelimiterAlloc(gpa, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        defer gpa.free(line);

        timer.reset();
        defer {
            std.debug.print("Took {} ns to complete request.\n", .{timer.lap()});
        }

        const trimmed_line = std.mem.trim(u8, line, "\n \t\r");
        if (trimmed_line.len == cache_reload_command.len and std.mem.eql(u8, trimmed_line, cache_reload_command)) {
            var reloaded: usize = 0;
            var it = doc_store.handles.iterator();
            while (it.next()) |entry| {
                if (entry.value == root_handle) {
                    continue;
                }

                // This was constructed from a path, it will never fail.
                const path = URI.parse(&arena.allocator, entry.key) catch |err| switch(err) {
                    error.OutOfMemory => return err,
                    else => unreachable,
                };

                const new_text = try std.fs.cwd().readFileAlloc(gpa, path, std.math.maxInt(usize));
                // Completely replace the whole text of the document
                gpa.free(entry.value.document.mem);
                entry.value.document.mem = new_text;
                entry.value.document.text = new_text;
                entry.value.tree.deinit();
                entry.value.tree = try std.zig.parse(gpa, new_text);
                entry.value.document_scope.deinit(gpa);
                entry.value.document_scope = try analysis.makeDocumentScope(gpa, entry.value.tree);

                reloaded += 1;
            }
            std.debug.print("Realoded {} of {} cached documents.\n", .{reloaded, doc_store.handles.count() - 1});
            continue;
        }

        var bound_type_params = analysis.BoundTypeParams.init(&arena.allocator);
        var tokenizer = std.zig.Tokenizer.init(std.mem.trim(u8, line, "\n \t"));
        if (try getFieldAccessType(&doc_store, &arena, root_handle, &tokenizer, &bound_type_params)) |result| {
            if (result.handle != root_handle) {
                switch (result.decl.*) {
                    .ast_node => |n| {
                        var handle = result.handle;
                        var node = n;
                        if (try analysis.resolveVarDeclAlias(&doc_store, &arena, .{ .node = node, .handle = result.handle })) |alias_result| {
                            switch (alias_result.decl.*) {
                                .ast_node => |inner| {
                                    handle = alias_result.handle;
                                    node = inner;
                                },
                                else => {},
                            }
                        } else if (node.cast(ast.Node.VarDecl)) |vdecl| try_import_resolve: {
                            if (vdecl.init_node) |init| {
                                if (init.cast(ast.Node.BuiltinCall)) |builtin| {
                                    if (std.mem.eql(u8, handle.tree.tokenSlice(builtin.builtin_token), "@import") and builtin.params_len == 1) {
                                        const import_type = (try result.resolveType(&doc_store, &arena, &bound_type_params)) orelse break :try_import_resolve;
                                        switch (import_type.type.data) {
                                            .other => |resolved_node| {
                                                handle = import_type.handle;
                                                node = resolved_node;
                                            },
                                            else => {},
                                        }
                                    }
                                }
                            }
                        }
                        const start_tok = if (analysis.getDocCommentNode(handle.tree, node)) |doc_comment|
                            doc_comment.first_line
                        else
                            node.firstToken();

                        const result_uri = handle.uri()[lib_uri.len..];

                        const start_loc = handle.tree.tokenLocation(0, start_tok);
                        const end_loc = handle.tree.tokenLocation(0, node.lastToken());
                        const github_uri = try std.fmt.allocPrint(&arena.allocator, "https://github.com/ziglang/zig/blob/master/lib{}#L{}-L{}\n", .{ result_uri, start_loc.line + 1, end_loc.line + 1 });
                        try std.io.getStdOut().writeAll(github_uri);
                        continue;
                    },
                    else => {},
                }
            }
        }
        std.debug.print("No match found\n", .{});
        try std.io.getStdOut().writeAll("\n");
    }
}
