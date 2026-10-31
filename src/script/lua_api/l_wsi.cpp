// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2026 Perttu Ahola <celeron55@gmail.com>

#include "lua_api/l_wsi.h"

#include "common/c_types.h"
#include "lua_api/l_internal.h"
#include "server.h"
#include "wsi/wsi_service.h"

// wsi_start(def) -> id
int ModApiWsi::l_wsi_start(lua_State *L)
{
	NO_MAP_LOCK_REQUIRED;
	WsiService *wsi = getServer(L)->getWsi();
	if (!wsi)
		throw LuaError("WSI agent support is not ready");
	return wsi->startAgent(L);
}

// wsi_stop(id)
int ModApiWsi::l_wsi_stop(lua_State *L)
{
	NO_MAP_LOCK_REQUIRED;
	WsiService *wsi = getServer(L)->getWsi();
	if (!wsi)
		throw LuaError("WSI agent support is not ready");
	wsi->stopAgent(L);
	return 0;
}

void ModApiWsi::Initialize(lua_State *L, int top)
{
	API_FCT(wsi_start);
	API_FCT(wsi_stop);
}
