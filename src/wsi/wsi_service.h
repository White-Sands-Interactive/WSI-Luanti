// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2026 Perttu Ahola <celeron55@gmail.com>

#pragma once

#include <memory>
#include <string>

struct lua_State;
class Server;

/// Owns the WSI agent runtime for one server. Tool calls are queued and run
/// on the server thread. turn() runs on a worker thread.
class WsiService {
public:
	explicit WsiService(Server *server);
	~WsiService();

	WsiService(const WsiService &) = delete;
	WsiService &operator=(const WsiService &) = delete;

	/// Run queued tool calls. Call only from the server thread, with the env lock held.
	void drainJobs(lua_State *L);
	/// Unblock tool calls that are waiting for a server step.
	void failPending(const std::string &reason);
	/// Abort turns, join the worker, and drop Lua refs. Safe to call twice.
	void shutdown(lua_State *L);

	int startAgent(lua_State *L);
	void stopAgent(lua_State *L);

private:
	struct Impl;
	std::unique_ptr<Impl> impl_;
};
