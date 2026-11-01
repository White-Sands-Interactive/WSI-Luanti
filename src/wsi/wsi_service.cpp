// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2026 Perttu Ahola <celeron55@gmail.com>

#include "wsi/wsi_service.h"

#include "common/c_types.h"
#include "config.h"
#include "filesys.h"
#include "log.h"
#include "server.h"
#include "settings.h"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#if USE_WSI
#include "wsi/agent_player.hpp"
#endif

namespace {
int luaAbsIndex(lua_State *L, int index)
{
	if (index > 0 || index <= LUA_REGISTRYINDEX)
		return index;
	return lua_gettop(L) + index + 1;
}

std::string luaFieldString(lua_State *L, int table, const char *key)
{
	lua_getfield(L, table, key);
	std::string value;
	if (lua_isstring(L, -1))
		value = lua_tostring(L, -1);
	lua_pop(L, 1);
	return value;
}
}

#if !USE_WSI

struct WsiService::Impl {};

WsiService::WsiService(Server *) : impl_(std::make_unique<Impl>()) {}

WsiService::~WsiService() = default;

void WsiService::drainJobs(lua_State *) {}

void WsiService::failPending(const std::string &) {}

void WsiService::shutdown(lua_State *) {}

int WsiService::startAgent(lua_State *)
{
	throw LuaError("WSI agent support is not built in");
}

void WsiService::stopAgent(lua_State *) {}

void WsiService::requestTurn(lua_State *)
{
	throw LuaError("WSI agent support is not built in");
}

int WsiService::pushSubgoals(lua_State *)
{
	throw LuaError("WSI agent support is not built in");
}

#else

namespace {

constexpr int JOB_WAIT_MS = 3000;
constexpr int ACTION_TIMEOUT_S = 60;
constexpr int PENDING_SLEEP_MS = 50;
constexpr int TURN_GAP_S = 1;
constexpr int SHUTDOWN_WAIT_S = 5;

std::string platformKey()
{
	std::string key = g_settings->get("secure.wsi_platform_key");
	if (key.empty())
		key = g_settings->get("wsi_platform_key");
	if (key.empty()) {
		if (const char *env = std::getenv("WSI_PLATFORM_KEY"))
			key = env;
	}
	return key;
}

bool integralNumber(double number)
{
	if (!std::isfinite(number))
		return false;
	const double whole = std::trunc(number);
	return whole == number &&
			number >= static_cast<double>(std::numeric_limits<long long>::min()) &&
			number <= static_cast<double>(std::numeric_limits<long long>::max());
}

void pushJson(lua_State *L, const wsi::Json &value)
{
	if (value.is_null()) {
		lua_pushnil(L);
	} else if (value.is_boolean()) {
		lua_pushboolean(L, value.get<bool>());
	} else if (value.is_number_integer()) {
		lua_pushinteger(L, static_cast<lua_Integer>(value.get<long long>()));
	} else if (value.is_number()) {
		lua_pushnumber(L, value.get<double>());
	} else if (value.is_string()) {
		const std::string text = value.get<std::string>();
		lua_pushlstring(L, text.data(), text.size());
	} else if (value.is_array()) {
		lua_newtable(L);
		int index = 1;
		for (const auto &item : value) {
			pushJson(L, item);
			lua_rawseti(L, -2, index);
			index++;
		}
	} else if (value.is_object()) {
		lua_newtable(L);
		for (auto it = value.begin(); it != value.end(); ++it) {
			pushJson(L, it.value());
			lua_setfield(L, -2, it.key().c_str());
		}
	} else {
		lua_pushnil(L);
	}
}

wsi::Json luaToJson(lua_State *L, int index, int depth);

wsi::Json tableToJson(lua_State *L, int index, int depth)
{
	const int abs = luaAbsIndex(L, index);
	const size_t length = lua_objlen(L, abs);
	bool array = true;
	size_t keys = 0;
	lua_pushnil(L);
	while (lua_next(L, abs) != 0) {
		keys++;
		if (lua_type(L, -2) != LUA_TNUMBER) {
			array = false;
		} else {
			const double key = lua_tonumber(L, -2);
			if (key < 1 || key != std::trunc(key) || key > static_cast<double>(length))
				array = false;
		}
		lua_pop(L, 1);
	}
	if (keys == 0 || (array && keys == length)) {
		wsi::Json out = wsi::Json::array();
		for (size_t i = 1; i <= length; i++) {
			lua_rawgeti(L, abs, static_cast<int>(i));
			out.push_back(luaToJson(L, -1, depth + 1));
			lua_pop(L, 1);
		}
		return out;
	}
	wsi::Json out = wsi::Json::object();
	lua_pushnil(L);
	while (lua_next(L, abs) != 0) {
		std::string key;
		if (lua_type(L, -2) == LUA_TSTRING) {
			key = lua_tostring(L, -2);
		} else if (lua_type(L, -2) == LUA_TNUMBER) {
			key = std::to_string(static_cast<long long>(lua_tonumber(L, -2)));
		}
		if (!key.empty())
			out[std::move(key)] = luaToJson(L, -1, depth + 1);
		lua_pop(L, 1);
	}
	return out;
}

wsi::Json luaToJson(lua_State *L, int index, int depth)
{
	if (depth > 8)
		throw std::runtime_error("value is too deep");
	index = luaAbsIndex(L, index);
	switch (lua_type(L, index)) {
	case LUA_TNIL:
		return nullptr;
	case LUA_TBOOLEAN:
		return lua_toboolean(L, index) ? true : false;
	case LUA_TNUMBER: {
		const double number = lua_tonumber(L, index);
		if (integralNumber(number))
			return static_cast<long long>(number);
		return number;
	}
	case LUA_TSTRING:
		return std::string(lua_tostring(L, index));
	case LUA_TTABLE:
		return tableToJson(L, index, depth);
	default:
		throw std::runtime_error("unsupported lua value");
	}
}

wsi::ArgSpec specFor(const std::string &name, const std::string &type)
{
	if (name.empty())
		throw LuaError("wsi_start: action param is missing a name");
	if (type == "integer")
		return wsi::integer(name);
	if (type == "number")
		return wsi::number(name);
	if (type == "string")
		return wsi::string(name);
	if (type == "boolean")
		return wsi::boolean(name);
	if (type == "array")
		return wsi::array_of(name, wsi::ArgKind::Object);
	throw LuaError("wsi_start: unsupported param type \"" + type + "\"");
}

struct LuaRefs {
	lua_State *L = nullptr;
	std::vector<int> refs;
	bool keep = false;

	explicit LuaRefs(lua_State *state) : L(state) {}

	~LuaRefs()
	{
		if (keep || !L)
			return;
		for (int ref : refs)
			luaL_unref(L, LUA_REGISTRYINDEX, ref);
	}

	LuaRefs(const LuaRefs &) = delete;
	LuaRefs &operator=(const LuaRefs &) = delete;

	int adopt(int ref)
	{
		refs.push_back(ref);
		return ref;
	}
};

}  // namespace

struct WsiService::Impl {
	enum class Work { None, Start, Turn, Stop };

	struct Agent;

	class LuaPlayer : public wsi::Player {
	public:
		LuaPlayer(Impl *impl, Agent *agent);
		std::string type_name() const override { return "Villager"; }

	private:
		Impl *m_impl;
		Agent *m_agent;
	};

	struct Agent {
		struct Action {
			std::string name;
			std::string description;
			std::vector<wsi::ArgSpec> specs;
			int run_ref = LUA_NOREF;
		};

		int id = 0;
		std::string name;
		std::string goal;
		int see_ref = LUA_NOREF;
		std::vector<Action> actions;
		std::unique_ptr<LuaPlayer> player;
		wsi::AgentHandle handle;
		wsi::Subscription events;
		wsi::AbortSignal abort;
		std::atomic<bool> stop{false};
		std::atomic<bool> started{false};
		std::atomic<bool> start_failed{false};
		std::atomic<bool> session_ended{false};
		std::atomic<bool> needs_cleanup{false};
		std::atomic<bool> cleaned{false};
		std::atomic<int> turns_due{0};
		struct Subgoal {
			std::string id;
			std::string objective;
			std::string progress;
		};
		std::mutex subgoal_mu;
		std::vector<Subgoal> subgoals;
	};

	struct Job {
		int ref = LUA_NOREF;
		wsi::Json args = wsi::Json::object();
		std::vector<wsi::ArgSpec> specs;
		bool done = false;
		bool pending = false;
		wsi::Json result = nullptr;
		std::string error;
		std::mutex mu;
		std::condition_variable cv;
	};

	struct JobResult {
		bool pending = false;
		wsi::Json json = nullptr;
	};

	struct Flight {
		Impl *impl;
		explicit Flight(Impl *owner) : impl(owner)
		{
			std::lock_guard lock(impl->mu);
			impl->in_flight++;
		}
		~Flight()
		{
			std::lock_guard lock(impl->mu);
			if (impl->in_flight > 0)
				impl->in_flight--;
			impl->cv.notify_all();
		}
		Flight(const Flight &) = delete;
		Flight &operator=(const Flight &) = delete;
	};

	explicit Impl(Server *server);
	~Impl();

	void drainJobs(lua_State *L);
	void failPending(const std::string &reason);
	void shutdown(lua_State *L);
	int startAgent(lua_State *L);
	void stopAgent(lua_State *L);
	void requestTurn(lua_State *L);
	int pushSubgoals(lua_State *L);
	wsi::Json callLua(int ref, const wsi::Json &args, const std::vector<wsi::ArgSpec> &specs);

	std::string world_path;
	std::unique_ptr<wsi::AgentServer> platform;
	std::vector<std::unique_ptr<Agent>> agents;
	std::vector<std::shared_ptr<Job>> queue;
	std::mutex mu;
	std::condition_variable cv;
	std::atomic<bool> closing{false};
	bool finished = false;
	int in_flight = 0;
	int next_id = 1;
	size_t cursor = 0;
	std::thread thread;

	void ensureServer(const std::string &key);
	std::vector<std::shared_ptr<Job>> takeJobs(bool stop);
	void finishJob(const std::shared_ptr<Job> &job, const wsi::Json &result, bool pending,
			const std::string &error);
	JobResult postJob(int ref, const wsi::Json &args, const std::vector<wsi::ArgSpec> &specs);
	void runJob(lua_State *L, const std::shared_ptr<Job> &job);
	void releaseAgent(lua_State *L, Agent *agent);
	bool hasWork() const;
	Work pick(Agent *&out);
	void doStart(Agent *agent);
	void doTurn(Agent *agent);
	void doStop(Agent *agent);
	void rememberSubgoal(Agent *agent, const wsi::AgentEvent &event);
	void workerMain();
};

WsiService::Impl::LuaPlayer::LuaPlayer(Impl *impl, Agent *agent) :
		m_impl(impl), m_agent(agent)
{
	set_description(agent->name);
	bind_dynamic("see", "", {}, [this](const wsi::Json &) {
		return m_impl->callLua(m_agent->see_ref, wsi::Json::object(), {});
	});
	for (const auto &action : agent->actions) {
		const int ref = action.run_ref;
		const std::vector<wsi::ArgSpec> specs = action.specs;
		bind_dynamic(action.name, action.description, action.specs,
				[this, ref, specs](const wsi::Json &args) {
					return m_impl->callLua(ref, args, specs);
				});
	}
}

WsiService::Impl::Impl(Server *owner) : world_path(owner->getWorldPath())
{
	thread = std::thread([this] { workerMain(); });
}

WsiService::Impl::~Impl()
{
	shutdown(nullptr);
}

void WsiService::Impl::ensureServer(const std::string &key)
{
	if (platform)
		return;
	wsi::AgentServerOptions options;
	options.platform_key = key;
	options.memory_path = world_path + DIR_DELIM + "wsi" + DIR_DELIM + "agent-memory.sqlite";
	options.turn_timeout_ms = 60000;
	options.logger.warn = [](const std::string &message) {
		warningstream << "WSI: " << message << std::endl;
	};
	options.logger.error = [](const std::string &message) {
		errorstream << "WSI: " << message << std::endl;
	};
	options.logger.info = [](const std::string &message) {
		infostream << "WSI: " << message << std::endl;
	};
	platform = std::make_unique<wsi::AgentServer>(std::move(options));
}

std::vector<std::shared_ptr<WsiService::Impl::Job>> WsiService::Impl::takeJobs(bool stop)
{
	std::lock_guard lock(mu);
	if (stop)
		closing = true;
	std::vector<std::shared_ptr<Job>> jobs;
	jobs.swap(queue);
	cv.notify_all();
	return jobs;
}

void WsiService::Impl::finishJob(const std::shared_ptr<Job> &job, const wsi::Json &result,
		bool pending, const std::string &error)
{
	std::lock_guard lock(job->mu);
	if (job->done)
		return;
	job->result = result;
	job->pending = pending;
	job->error = error;
	job->done = true;
	job->cv.notify_all();
}

void WsiService::Impl::failPending(const std::string &reason)
{
	const std::vector<std::shared_ptr<Job>> jobs = takeJobs(false);
	for (const auto &job : jobs)
		finishJob(job, nullptr, false, reason);
}

WsiService::Impl::JobResult WsiService::Impl::postJob(int ref, const wsi::Json &args,
		const std::vector<wsi::ArgSpec> &specs)
{
	auto job = std::make_shared<Job>();
	job->ref = ref;
	job->args = args;
	job->specs = specs;
	{
		std::lock_guard lock(mu);
		if (closing.load())
			throw std::runtime_error("server shutting down");
		queue.push_back(job);
	}
	std::unique_lock lock(job->mu);
	if (!job->cv.wait_for(lock, std::chrono::milliseconds(JOB_WAIT_MS), [&] { return job->done; }))
		throw std::runtime_error("server did not run the action in time");
	if (!job->error.empty())
		throw std::runtime_error(job->error);
	JobResult result;
	result.pending = job->pending;
	result.json = std::move(job->result);
	return result;
}

void WsiService::Impl::runJob(lua_State *L, const std::shared_ptr<Job> &job)
{
	StackUnroller unroller(L);
	try {
		lua_rawgeti(L, LUA_REGISTRYINDEX, job->ref);
		if (!lua_isfunction(L, -1))
			throw std::runtime_error("agent callback is gone");
		for (const auto &spec : job->specs) {
			if (!job->args.is_object() || !job->args.contains(spec.name) || job->args.at(spec.name).is_null())
				lua_pushnil(L);
			else
				pushJson(L, job->args.at(spec.name));
		}
		if (lua_pcall(L, static_cast<int>(job->specs.size()), 1, 0) != 0) {
			const char *message = lua_tostring(L, -1);
			throw std::runtime_error(message ? message : "lua error");
		}
		bool pending = false;
		if (lua_istable(L, -1)) {
			lua_getfield(L, -1, "_pending");
			pending = lua_isboolean(L, -1) && lua_toboolean(L, -1);
			lua_pop(L, 1);
		}
		wsi::Json result = nullptr;
		if (!pending)
			result = luaToJson(L, -1, 0);
		lua_pop(L, 1);
		finishJob(job, result, pending, "");
	} catch (const std::exception &e) {
		finishJob(job, nullptr, false, e.what());
	}
}

wsi::Json WsiService::Impl::callLua(int ref, const wsi::Json &args,
		const std::vector<wsi::ArgSpec> &specs)
{
	Flight flight(this);
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(ACTION_TIMEOUT_S);
	while (true) {
		if (closing.load())
			throw std::runtime_error("server shutting down");
		if (std::chrono::steady_clock::now() >= deadline)
			throw std::runtime_error("action timed out");
		JobResult result = postJob(ref, args, specs);
		if (!result.pending)
			return result.json;
		std::unique_lock lock(mu);
		cv.wait_for(lock, std::chrono::milliseconds(PENDING_SLEEP_MS), [&] {
			return closing.load();
		});
	}
}

void WsiService::Impl::releaseAgent(lua_State *L, Agent *agent)
{
	if (agent->cleaned.exchange(true))
		return;
	if (L) {
		luaL_unref(L, LUA_REGISTRYINDEX, agent->see_ref);
		agent->see_ref = LUA_NOREF;
		for (auto &action : agent->actions) {
			luaL_unref(L, LUA_REGISTRYINDEX, action.run_ref);
			action.run_ref = LUA_NOREF;
		}
	}
	std::lock_guard lock(mu);
	agents.erase(std::remove_if(agents.begin(), agents.end(),
			[&](const std::unique_ptr<Agent> &item) {
				return item.get() == agent;
			}),
			agents.end());
}

void WsiService::Impl::drainJobs(lua_State *L)
{
	std::vector<std::shared_ptr<Job>> jobs;
	std::vector<Agent *> cleanup;
	{
		std::lock_guard lock(mu);
		jobs.swap(queue);
		for (auto &agent : agents) {
			if (agent->needs_cleanup.load() && !agent->cleaned.load())
				cleanup.push_back(agent.get());
		}
	}
	for (const auto &job : jobs)
		runJob(L, job);
	for (Agent *agent : cleanup)
		releaseAgent(L, agent);
}

bool WsiService::Impl::hasWork() const
{
	for (const auto &agent : agents) {
		if (!agent || agent->cleaned.load() || agent->needs_cleanup.load())
			continue;
		if (agent->stop.load())
			return true;
		if (!agent->started.load() && !agent->start_failed.load())
			return true;
		if (agent->started.load() && !agent->session_ended.load() &&
				agent->turns_due.load() > 0)
			return true;
	}
	return false;
}

WsiService::Impl::Work WsiService::Impl::pick(Agent *&out)
{
	if (agents.empty())
		return Work::None;
	const size_t count = agents.size();
	for (size_t i = 0; i < count; i++) {
		Agent *agent = agents[(cursor + i) % count].get();
		if (!agent || agent->cleaned.load() || agent->needs_cleanup.load())
			continue;
		if (agent->stop.load()) {
			if (agent->started.load() && !agent->session_ended.load()) {
				cursor = (cursor + i + 1) % count;
				out = agent;
				return Work::Stop;
			}
			agent->needs_cleanup = true;
			continue;
		}
		if (!agent->started.load() && !agent->start_failed.load()) {
			cursor = (cursor + i + 1) % count;
			out = agent;
			return Work::Start;
		}
		if (agent->started.load() && !agent->session_ended.load() &&
				agent->turns_due.load() > 0) {
			agent->turns_due.fetch_sub(1);
			cursor = (cursor + i + 1) % count;
			out = agent;
			return Work::Turn;
		}
	}
	return Work::None;
}

namespace {

std::string jsonField(const wsi::Json &value, const char *key)
{
	if (!value.is_object() || !value.contains(key) || value.at(key).is_null())
		return {};
	const wsi::Json &item = value.at(key);
	if (item.is_string())
		return item.get<std::string>();
	if (item.is_number_integer())
		return std::to_string(item.get<long long>());
	return {};
}

void noteSubgoal(const std::string &name, const wsi::AgentEvent &event)
{
	const std::string action = event.action.value_or("subgoal");
	const wsi::Json args = event.args.value_or(wsi::Json::object());
	const std::string id = jsonField(args, "id");
	std::string detail = jsonField(args, "objective");
	if (detail.empty())
		detail = jsonField(args, "progress");
	if (event.error && !event.error->empty()) {
		warningstream << "WSI " << name << " subgoal rejected " << action;
		if (!id.empty())
			warningstream << " " << id;
		warningstream << ": " << *event.error << std::endl;
		return;
	}
	actionstream << "WSI " << name << " subgoal " << action;
	if (!id.empty())
		actionstream << " " << id;
	if (!detail.empty())
		actionstream << ": " << detail;
	actionstream << std::endl;
}

}  // namespace

void WsiService::Impl::doStart(Agent *agent)
{
	if (closing.load() || agent->stop.load()) {
		agent->needs_cleanup = true;
		return;
	}
	try {
		wsi::StartOptions options;
		options.name = agent->name;
		if (!agent->goal.empty())
			options.goal = agent->goal;
		agent->handle = platform->start(*agent->player, options);
		agent->events = agent->handle.on([this, agent, name = agent->name](const wsi::AgentEvent &event) {
			if (event.type != "subgoal")
				return;
			noteSubgoal(name, event);
			rememberSubgoal(agent, event);
		});
		if (agent->stop.load() || closing.load()) {
			try {
				agent->handle.stop();
			} catch (const std::exception &e) {
				warningstream << "WSI " << agent->name << " stop: " << e.what() << std::endl;
			}
			agent->session_ended = true;
			agent->needs_cleanup = true;
			return;
		}
		agent->started = true;
		actionstream << "WSI " << agent->name << " session started" << std::endl;
	} catch (const std::exception &e) {
		agent->start_failed = true;
		agent->needs_cleanup = true;
		errorstream << "WSI " << agent->name << " failed to start: " << e.what() << std::endl;
	}
}

void WsiService::Impl::rememberSubgoal(Agent *agent, const wsi::AgentEvent &event)
{
	if (event.error && !event.error->empty())
		return;
	const std::string action = event.action.value_or("");
	const wsi::Json args = event.args.value_or(wsi::Json::object());
	const std::string id = jsonField(args, "id");
	if (id.empty())
		return;
	std::lock_guard lock(agent->subgoal_mu);
	if (action == "complete_subgoal") {
		agent->subgoals.erase(std::remove_if(agent->subgoals.begin(), agent->subgoals.end(),
				[&](const Agent::Subgoal &item) { return item.id == id; }),
				agent->subgoals.end());
		return;
	}
	Agent::Subgoal *found = nullptr;
	for (auto &item : agent->subgoals) {
		if (item.id == id) {
			found = &item;
			break;
		}
	}
	if (action == "add_subgoal") {
		if (!found) {
			agent->subgoals.push_back(Agent::Subgoal{});
			found = &agent->subgoals.back();
			found->id = id;
		}
		const std::string objective = jsonField(args, "objective");
		if (!objective.empty())
			found->objective = objective;
		return;
	}
	if (action == "update_subgoal" && found)
		found->progress = jsonField(args, "progress");
}

void WsiService::Impl::doTurn(Agent *agent)
{
	if (closing.load() || agent->stop.load())
		return;
	try {
		wsi::TurnOptions options;
		options.timeout_ms = 60000;
		options.signal = &agent->abort;
		const wsi::TurnResult result = agent->handle.turn(options);
		actionstream << "WSI " << agent->name << " did " << result.action << std::endl;
	} catch (const std::exception &e) {
		if (closing.load() || agent->stop.load())
			infostream << "WSI " << agent->name << " stopped: " << e.what() << std::endl;
		else
			warningstream << "WSI " << agent->name << " turn failed: " << e.what() << std::endl;
	}
	std::unique_lock lock(mu);
	cv.wait_for(lock, std::chrono::seconds(TURN_GAP_S), [&] {
		return closing.load() || agent->stop.load();
	});
}

void WsiService::Impl::doStop(Agent *agent)
{
	if (!closing.load() && agent->started.load() && !agent->session_ended.load()) {
		try {
			agent->handle.stop();
		} catch (const std::exception &e) {
			warningstream << "WSI " << agent->name << " stop: " << e.what() << std::endl;
		}
	}
	agent->session_ended = true;
	agent->needs_cleanup = true;
}

void WsiService::Impl::workerMain()
{
	while (!closing.load()) {
		Agent *agent = nullptr;
		Work work = Work::None;
		{
			std::unique_lock lock(mu);
			work = pick(agent);
			if (work == Work::None) {
				cv.wait_for(lock, std::chrono::milliseconds(200), [&] {
					return closing.load() || hasWork();
				});
				continue;
			}
		}
		if (closing.load())
			break;
		try {
			switch (work) {
			case Work::None:
				break;
			case Work::Start:
				doStart(agent);
				break;
			case Work::Turn:
				doTurn(agent);
				break;
			case Work::Stop:
				doStop(agent);
				break;
			}
		} catch (const std::exception &e) {
			warningstream << "WSI worker: " << e.what() << std::endl;
		}
	}
}

int WsiService::Impl::startAgent(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	const std::string key = platformKey();
	if (key.empty()) {
		throw LuaError(
				"Set wsi_platform_key or the WSI_PLATFORM_KEY environment variable");
	}
	try {
		ensureServer(key);
	} catch (const LuaError &) {
		throw;
	} catch (const std::exception &e) {
		throw LuaError(std::string("wsi_start: ") + e.what());
	}

	int id = 0;
	{
		LuaRefs refs(L);
		StackUnroller unroller(L);
		const std::string given_name = luaFieldString(L, 1, "name");
		const std::string name = given_name.empty() ? "Villager" : given_name;
		const std::string goal = luaFieldString(L, 1, "goal");

		lua_getfield(L, 1, "see");
		if (!lua_isfunction(L, -1))
			throw LuaError("wsi_start: see must be a function");
		const int see_ref = refs.adopt(luaL_ref(L, LUA_REGISTRYINDEX));

		lua_getfield(L, 1, "actions");
		if (!lua_istable(L, -1))
			throw LuaError("wsi_start: actions must be a table");
		const int actions = luaAbsIndex(L, -1);
		std::vector<Agent::Action> parsed;
		lua_pushnil(L);
		while (lua_next(L, actions) != 0) {
			if (!lua_istable(L, -1))
				throw LuaError("wsi_start: each action must be a table");
			const int action = luaAbsIndex(L, -1);
			Agent::Action item;
			item.name = luaFieldString(L, action, "name");
			item.description = luaFieldString(L, action, "description");
			if (item.name.empty() || item.name == "see" || item.name == "wait" || item.name.front() == '_')
				throw LuaError("wsi_start: cannot publish action \"" + item.name + "\"");
			for (const auto &existing : parsed) {
				if (existing.name == item.name)
					throw LuaError("wsi_start: duplicate action \"" + item.name + "\"");
			}
			lua_getfield(L, action, "params");
			if (!lua_isnil(L, -1)) {
				if (!lua_istable(L, -1))
					throw LuaError("wsi_start: action params must be a table");
				const int params = luaAbsIndex(L, -1);
				lua_pushnil(L);
				while (lua_next(L, params) != 0) {
					if (!lua_istable(L, -1))
						throw LuaError("wsi_start: each param must be a table");
					const int param = luaAbsIndex(L, -1);
					item.specs.push_back(specFor(
							luaFieldString(L, param, "name"),
							luaFieldString(L, param, "type")));
					lua_pop(L, 1);
				}
			}
			lua_pop(L, 1);
			lua_getfield(L, action, "run");
			if (!lua_isfunction(L, -1))
				throw LuaError("wsi_start: action run must be a function");
			item.run_ref = refs.adopt(luaL_ref(L, LUA_REGISTRYINDEX));
			parsed.push_back(std::move(item));
			lua_pop(L, 1);
		}
		lua_pop(L, 1);

		auto agent = std::make_unique<Agent>();
		agent->name = name;
		agent->goal = goal;
		agent->see_ref = see_ref;
		agent->actions = std::move(parsed);
		try {
			agent->player = std::make_unique<LuaPlayer>(this, agent.get());
		} catch (const LuaError &) {
			throw;
		} catch (const std::exception &e) {
			throw LuaError(std::string("wsi_start: ") + e.what());
		}
		{
			std::lock_guard lock(mu);
			agent->id = next_id++;
			id = agent->id;
			agents.push_back(std::move(agent));
			cv.notify_all();
		}
		refs.keep = true;
	}
	lua_pushinteger(L, id);
	return 1;
}

void WsiService::Impl::requestTurn(lua_State *L)
{
	const int id = luaL_checkinteger(L, 1);
	std::lock_guard lock(mu);
	for (auto &agent : agents) {
		if (agent->id != id || agent->cleaned.load() || agent->stop.load())
			continue;
		agent->turns_due.fetch_add(1);
		cv.notify_all();
		return;
	}
}

int WsiService::Impl::pushSubgoals(lua_State *L)
{
	const int id = luaL_checkinteger(L, 1);
	std::vector<Agent::Subgoal> copy;
	{
		std::lock_guard lock(mu);
		for (auto &agent : agents) {
			if (agent->id != id || agent->cleaned.load())
				continue;
			std::lock_guard goals(agent->subgoal_mu);
			copy = agent->subgoals;
			break;
		}
	}
	lua_newtable(L);
	int index = 1;
	for (const auto &item : copy) {
		lua_newtable(L);
		lua_pushlstring(L, item.id.data(), item.id.size());
		lua_setfield(L, -2, "id");
		lua_pushlstring(L, item.objective.data(), item.objective.size());
		lua_setfield(L, -2, "objective");
		lua_pushlstring(L, item.progress.data(), item.progress.size());
		lua_setfield(L, -2, "progress");
		lua_rawseti(L, -2, index);
		index++;
	}
	return 1;
}

void WsiService::Impl::stopAgent(lua_State *L)
{
	const int id = luaL_checkinteger(L, 1);
	std::lock_guard lock(mu);
	for (auto &agent : agents) {
		if (agent->id != id || agent->cleaned.load())
			continue;
		agent->stop = true;
		agent->abort.abort("stopped");
		cv.notify_all();
		return;
	}
}

void WsiService::Impl::shutdown(lua_State *L)
{
	if (finished)
		return;
	finished = true;
	const std::vector<std::shared_ptr<Job>> jobs = takeJobs(true);
	for (const auto &job : jobs)
		finishJob(job, nullptr, false, "server shutting down");

	std::vector<Agent *> snapshot;
	{
		std::lock_guard lock(mu);
		for (auto &agent : agents)
			snapshot.push_back(agent.get());
	}
	for (Agent *agent : snapshot) {
		try {
			agent->abort.abort("server shutting down");
		} catch (const std::exception &) {
		}
	}
	if (platform) {
		try {
			platform->interrupt();
		} catch (const std::exception &e) {
			warningstream << "WSI interrupt: " << e.what() << std::endl;
		}
	}
	{
		std::unique_lock lock(mu);
		cv.wait_for(lock, std::chrono::seconds(SHUTDOWN_WAIT_S), [&] {
			return in_flight == 0;
		});
	}
	if (thread.joinable())
		thread.join();
	for (Agent *agent : snapshot)
		releaseAgent(L, agent);
	try {
		platform.reset();
	} catch (const std::exception &e) {
		warningstream << "WSI close: " << e.what() << std::endl;
	}
}

WsiService::WsiService(Server *server) : impl_(std::make_unique<Impl>(server)) {}

WsiService::~WsiService()
{
	shutdown(nullptr);
}

void WsiService::drainJobs(lua_State *L)
{
	impl_->drainJobs(L);
}

void WsiService::failPending(const std::string &reason)
{
	impl_->failPending(reason);
}

void WsiService::shutdown(lua_State *L)
{
	if (impl_)
		impl_->shutdown(L);
}

int WsiService::startAgent(lua_State *L)
{
	return impl_->startAgent(L);
}

void WsiService::stopAgent(lua_State *L)
{
	impl_->stopAgent(L);
}

void WsiService::requestTurn(lua_State *L)
{
	impl_->requestTurn(L);
}

int WsiService::pushSubgoals(lua_State *L)
{
	return impl_->pushSubgoals(L);
}

#endif
