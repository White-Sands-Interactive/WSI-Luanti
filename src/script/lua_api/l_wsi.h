// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2026 Perttu Ahola <celeron55@gmail.com>

#pragma once

#include "lua_api/l_base.h"

class ModApiWsi : public ModApiBase
{
private:
	// wsi_start({name, goal, see = function(), actions = {...}}) -> id
	static int l_wsi_start(lua_State *L);

	// wsi_stop(id)
	static int l_wsi_stop(lua_State *L);

public:
	static void Initialize(lua_State *L, int top);
};
