local dl = require("liblua_dlffi");

-- {{{ cast_table()
local cast_table = function(func, tbl)
	local val = tbl["_val"];
	if val and (val ~= dl.NULL) then return val end;
end;
-- }}} cast_table()

local Dlffi = {};
local Dlffi_t = {}; -- types container

-- {{{ load() <-> rawload()
local rawload = dl.load;
dl.rawload = rawload;

-- {{{ proxy for multi-return functions
local multireturn = function(proxy, ...)
	local arg = proxy.arg;
	local ret = proxy.ret;
	local struct = proxy.struct;
	local symbol = proxy.symbol;
	local val = {...};
	local new_val = {};
	-- {{{ substitute values with pointers
	for i = 1, #val, 1 do new_val[i] = val[i] end;
	for cx = 1, #ret, 1 do
		local i = ret[cx];
		local cur_v = new_val[i];
		if not cur_v then
			new_val[i] = dl.NULL;
		else -- {{{ wrap value
		local cur_t = arg[i];
		-- create buffer
		local buf, e = dl.dlffi_Pointer(
			dl.sizeof(cur_t),
			true
		);
		if not buf then return nil, e end;
		-- initialize buffer
		e = dl.type_element(
			buf,
			struct[cur_t],
			1,
			cur_v
		);
		if not e then return
			nil,
			"type_element() failed"
		end;
		-- substitute value
		new_val[i] = buf;
		end; -- }}} wrap value
	end;
	-- }}} substitute values with pointers
	-- jump to original symbol
	local retval, e = symbol(unpack(new_val));
	if e then return false, e end;
	-- get returned values
	local retvals = {};
	for cx = 1, #ret, 1 do
		local i = ret[cx];
		local buf = new_val[i];
		if buf == dl.NULL then
			table.insert(ret, dl.NULL);
		else -- {{{ unwrap value
		local cur_t = arg[i];
		e = dl.type_element(
			buf,
			struct[cur_t],
			1
		);
		if not e then return nil,
			"Return value unwrap failed";
		end;
		-- push return value
		table.insert(retvals, e);
		end; -- }}} unwrap value
	end;
	return true, retval, unpack(retvals);
end;
-- }}} proxy for multi-return functions

dl.load = function (lib, sym, ret, arg, cast)
	-- if a dynamic symbol is loading
	if type(lib) == "string" then
		if not cast then cast = cast_table end;
		if type(ret) == "table" then
			-- construct multi-return function
			-- ret may look like
			--	{ ret = ffi_type_pointer, 2, 3 }
			--	ret["ret"] is required key
			-- {{{ substitute given types with pointers
			local new_arg = {};
			for i = 1, #arg, 1 do
				new_arg[i] = arg[i];
			end;
			local struct = Dlffi_t:new();
			if not struct then
				return nil, "Dlffi_t:new() failed";
			end;
			for i = 1, #ret, 1 do
				local v = ret[i];
				local t = new_arg[v]
				if not t then
					return nil, string.format(
						"Argument #%d does not exists",
						i
					);
				end;
				if not struct[t] then
					struct[t] = { t };
					if not struct[t] then
						return nil, string.format(
							"Structure #%d " ..
							"construction failed",
							i
						);
					end;
				end;
				new_arg[v] = dl.ffi_type_pointer;
			end;
			-- }}} substitute given types with pointers
			-- load symbol with a real prototype
			local symbol, e =
				rawload(lib, sym, ret.ret, new_arg, cast);
			if not symbol then return nil, e end;
			-- {{{ make proxy object
			local proxy = newproxy(true);
			if not proxy then
				return nil, "newproxy() failed";
			end;
			local mt = getmetatable(proxy);
			if not mt then
				return nil, "newproxy has no metatable";
			end;
			mt.__index = mt;
			mt.__call = multireturn;
			mt.arg = arg;
			mt.ret = ret;
			mt.struct = struct;
			mt.symbol = symbol;
			-- }}} make proxy object
			-- return proxy instead of original one
			return proxy;
		end;
	end;
	return rawload(lib, sym, ret, arg, cast);
end;
-- }}} load() <-> rawload()

-- {{{ dlffi_Pointer() <-> rawdlffi_Pointer()
local rawdlffi_Pointer = dl.dlffi_Pointer;
dl.rawdlffi_Pointer = rawdlffi_Pointer;
local dlffi_Pointer = function(p, ...)
	if type(p) == "table" then
		return dlffi_Pointer(cast_table(dlffi.NULL, p), ...);
	end;
	return rawdlffi_Pointer(p, ...);
end;
dl.dlffi_Pointer = dlffi_Pointer;
-- }}} dlffi_Pointer() <-> rawdlffi_Pointer()

-- {{{ Dlffi
-- {{{ is_callable(obj) -- if the object can be called
local function is_callable(obj)
	if type(obj) == "function" then return true end;
	if type(obj) == "userdata" or type(obj) == "table" then
		local mt = getmetatable(obj);
		if not mt then return false end;
		return mt.__call ~= nil;
	end;
	return false;
end;
-- }}} is_callable()

function Dlffi:new(api, init, gc, spec)
	--[[
		api	- table of tables with API
		init	- userdata or anything
		gc	- destructor: void function(self)
		spec	- list of special functions
	--]]
	if type(init) == "table" then
		return self:new(api, init._val, gc, spec);
	end;
	local o = {};
	o._val = init;
	o._type = "object";
	if init == nil or init == dl.NULL then
		return nil, "Bad initial value specified";
	end;
	if not spec then spec = {} end;
	if gc ~= nil then
		if not is_callable(gc) then
			return nil, "GC must be a function";
		end;
		o._gc = newproxy(true);
		getmetatable(o._gc).__gc = function()
			local val = o._val;
			if (val ~= nil) and (val ~= dl.NULL) then gc(val) end;
		end;
	end;
	setmetatable(o, { __index = function (t, v)
		local f;
		-- find table with the requested key
		for i = 1, #api, 1 do
			f = rawget(api[i], v);
			if f ~= nil then break end;
		end;
		local constructor = spec[v]; -- if a constructor requested
		if not constructor then return f end;
		-- get it's GC
		local gc = is_callable(constructor) and constructor or nil;
		-- construct appropriate proxy function
		return function(obj, ...)
			return self:new(
				api,
				f(obj, ...),
				gc,
				spec
			);
		end;
	end });
	return o;
end;
-- }}} Dlffi

-- {{{ Dlffi_t
function Dlffi_t:new(k, v)
	local o = {
		types = {},
		tables = {},
		gc = newproxy(true),
	};
	if o.gc == nil then return nil, "newproxy() failed" end;
	getmetatable(o.gc).__gc = function()
		for k, v in pairs(o.types) do
			if type(v) == "userdata" then
				dl.type_free(v);
				o.types[k] = nil;
			end;
		end;
	end;
	setmetatable(o,
		{
		__index = function(t, k)
			local v = rawget(t, k);
			if v then return v end;
			local v = t.types;
			if v == nil then return nil end;
			return v[k];
		end,
		__newindex = function(t, k, v)
			local s = t.types[k];
			if s ~= nil then
				-- free the initialized type
				dl.type_free(s);
				t.types[k] = nil;
				t.tables[v] = nil;
			end;
			-- initialize the new type
			local new = dl.type_init(v);
			if new ~= nil then
				t.types[k] = new;
				t.tables[k] = v;
			end;
		end
		}
	);
	if type(v) == "table" then
		o[k] = v;
		if o.types[k] == nil then
			return nil, "type initialization failed";
		end;
	end;
	return o;
end;
-- }}} Dlffi_t

dl.Dlffi = Dlffi;
dl.Dlffi_t = Dlffi_t;
dl.cast_table = cast_table;
return dl;

