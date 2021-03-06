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

local memset, e = rawload("", "memset", dl.ffi_type_pointer,
	{dl.ffi_type_pointer, dl.ffi_type_sint, dl.ffi_type_size_t} );
assert(memset, e);

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
		-- initialize buffer if needed
		if (cur_v == dl.NULL) then
			-- bzero
			memset(buf, 0, dl.sizeof(cur_t));
		else
			e = dl.type_element(
				buf,
				struct[cur_t],
				1,
				cur_v
			);
			if not e then return
				nil,
				string.format(
					"type_element() failed for #%d",
					i
				);
			end;
		end;
		-- substitute value
		new_val[i] = buf;
		end; -- }}} wrap value
	end;
	-- }}} substitute values with pointers
	-- jump to original symbol
	local retval, e = symbol(table.unpack(new_val));
	if e then return false, e end;
	-- get returned values
	local retvals = {};
	for cx = 1, #ret, 1 do
		local i = ret[cx];
		local buf = new_val[i];
		if buf == dl.NULL then
			table.insert(retvals, dl.NULL);
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
	return true, retval, table.unpack(retvals);
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
			local proxy = {};
			local mt = {};
			setmetatable(proxy, mt);
			mt.__index = mt;
			mt.__call = multireturn;
			mt.arg = arg;
			mt.ret = ret;
			mt.struct = struct;
			mt.symbol = symbol;
			-- }}} make proxy object
			-- return proxy and the original symbol
			return proxy, symbol;
		end;
	end;
	return rawload(lib, sym, ret, arg, cast);
end;
-- }}} load() <-> rawload()

-- {{{ loadsym() - load a dynamic symbol, that is not a function
--	lib	- library name
--	name	- dynamic symbol name
--	ffitype	- FFI type of the loading symbol
local function loadsym(lib, name, ffitype)
	local dlopen, e;
	dlopen, e = dl.load(
		"", "dlopen", dl.ffi_type_pointer,
		{ dl.ffi_type_pointer, dl.ffi_type_sint }
	);
	if not dlopen then return nil, "dlopen(): " .. tostring(e) end;
	local dlsym;
	dlsym, e = dl.load(
		"", "dlsym", dl.ffi_type_pointer,
		{ dl.ffi_type_pointer, dl.ffi_type_pointer }
	);
	if not dlsym then return nil, "dlsym(): " .. tostring(e) end;
	local dlclose;
	dlclose, e = dl.load(
		"", "dlclose", dl.ffi_type_sint,
		{ dl.ffi_type_pointer }
	);
	if not dlclose then return nil, "dlclose(): " .. tostring(e) end;
	local dlerror;
	dlerror, e = dl.load(
		"", "dlerror", dl.ffi_type_pointer,
		{ }
	);
	if not dlerror then return nil, "dlerror(): " .. tostring(e) end;
	local dll, e;
	if lib == "" then lib = dl.NULL end;
	dll, e = dlopen(lib, 2);
	if not dll then return nil, "lib opening: " .. tostring(e) end;
	if dll == dl.NULL then
		e = dl.dlffi_Pointer(dlerror()):tostring();
		return nil, "lib opening failed: " .. tostring(e);
	end;
	local sym;
	sym, e = dlsym(dll, name);
	if not sym then return nil, "symbol loading: " .. tostring(e) end;
	if sym == dl.NULL then return nil, "symbol loading failed" end;
	dlclose(dll);
	local o = {};
	o.symbol = sym;
	local struct;
	struct, e = Dlffi_t:new("main", { ffitype });
	if not struct then return nil, "Dlffi_t:new(): " .. tostring(e) end;
	o.struct = struct;
	local mt = {};
	mt.__call = function(t)
		return dl.type_element(t.symbol, t.struct["main"], 1);
	end;
	return setmetatable(o, mt);
end;
dl.loadsym = loadsym;
-- }}} loadsym()

-- {{{ dlffi_Pointer() <-> rawdlffi_Pointer()
--	accepts tables and strings:
--	table:	cast and call again
--	string:	duplicate \0-terminated Lua string and call rawdlffi_Pointer
local rawdlffi_Pointer = dl.dlffi_Pointer;
dl.rawdlffi_Pointer = rawdlffi_Pointer;
local dlffi_Pointer = function(p, ...)
	local t = type(p);
	if t == "table" then
		return dlffi_Pointer(cast_table(dl.NULL, p), ...);
	elseif t == "string" then
		local struct = Dlffi_t:new("void *", { dl.ffi_type_pointer });
		if not struct then return nil, "Dlffi_t:new() failed" end;
		local buf = struct:new("void *", true);
		if not buf then return nil, "malloc() failed" end;
		local r = dl.type_element(buf, struct["void *"], 1, p);
		if not r then return nil, "type_element() failed" end;
		r = dl.type_element(buf, struct["void *"], 1);
		if not r then
			return nil, "type_element() failed, leak possible";
		end;
		return rawdlffi_Pointer(r, ...);
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
		o._gc = setmetatable({}, {__gc = true});
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

-- {{{ Dlffi_t:new(...) - constructor
function Dlffi_t:new(k, v)
	local o = {
		-- table for FFI structures
		types = {},
		-- Lua tables corresponding to FFI structures
		-- or/and regular FFI types
		-- (GC-less values)
		tables = {},
		gc = setmetatable({}, {__gc = true}),
	};
	-- {{{ GC
	getmetatable(o.gc).__gc = function()
		o.tables = nil;
		for k, v in pairs(o.types) do
			if type(v) == "userdata" then
				dl.type_free(v);
				o.types[k] = nil;
			end;
		end;
	end;
	-- }}} GC
	setmetatable(o,
		{
		__index = function(t, k)
			local v = rawget(t, k);
			if v then return v end;
			v = t.types[k];
			if not v then
				v = t.tables[k];
			end;
			return v;
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
			if type(v) == "userdata" then
				-- regular non-structure FFI type
				t.tables[k] = v;
			else -- expect a Lua table
				local init = dl.type_init(v);
				if init then
					t.types[k] = init;
					t.tables[k] = v;
				end;
			end;
			return v;
		end
		}
	);
	if type(v) == "table" then
		o[k] = v;
		if o.types[k] == nil then
			return nil, "type initialization failed";
		end;
	end;
	rawset(o, "new", self.malloc);
	rawset(o, "get", self.get);
	rawset(o, "put", self.put);
	return o;
end;
-- }}} Dlffi_t:new()

-- {{{ Dlffi_t:malloc(...) - allocate buffer for named FFI type
function Dlffi_t:malloc(name, gc)
	if type(name) == "string" then name = self[name] end;
	return dl.dlffi_Pointer(dl.sizeof(name), gc);
end;
-- }}} Dlffi_t:malloc()

-- {{{ Dlffi_t:get() - type_element wrapper
function Dlffi_t:get(name, obj, num)
	if type(obj) == "table" then
		return self:get(name, cast_table(self.get, obj), num);
	end;
	if type(name) == "string" then name = self[name] end;
	return dl.type_element(obj, name, num);
end;
-- }}} Dlffi_t:get()

-- {{{ Dlffi_t:put() - type_element wrapper
function Dlffi_t:put(name, obj, num, val)
	if type(obj) == "table" then
		return self:put(name, cast_table(self.get, obj), num, val);
	end;
	if type(name) == "string" then name = self[name] end;
	return dl.type_element(obj, name, num, val);
end;
-- }}} Dlffi_t:put()

-- }}} Dlffi_t

-- {{{ Header
Header = {};

-- {{{ proxy_like(...)
local proxy_like;
proxy_like = function(symbol, obj)
	if type(symbol) ~= "table" then return obj end;
	if symbol.lookup then
		symbol.gc = symbol.lookup[symbol.gc];
		symbol.lookup = nil;
	end;
	return Dlffi:new(
		symbol.inherit,
		obj,
		symbol.gc
	);
end;
Header.proxy_like = proxy_like;
-- }}} proxy_like()

-- {{{ proxy_call(...)
local proxy_call = function(t, ...)
	if t.lookup then
		t.gc = t.lookup[t.gc];
		t.lookup = nil;
	end;
	return Dlffi:new(
		t.inherit,
		t.symbol(...),
		t.gc
	);
end;
Header.proxy_call = proxy_call;
-- }}} proxy_call()

-- {{{ proxy_string() - cast null-terminated string into Lua type
local proxy_string = function(t, ...)
	local gc = t.gc;
	if t.lookup then
		gc = t.lookup[t.gc];
		t.lookup = nil;
		t.gc = gc;
	end;
	local r, e = dl.dlffi_Pointer(t.symbol(...), gc == true);
	if not r then return nil, e end;
	if gc and (type(gc) ~= "boolean") then
		r:set_gc(gc);
	end;
	return r:tostring();
end;
Header.proxy_string = proxy_string;
-- }}} proxy_string()

-- {{{ Header.proxy(...) - make proxy function
--	symbol	- dynamic symbol or any reference
--	inherit	- table of inherrited chunks
--	gc	- GC flag or destructor name
--	lookup	- table to look for GC
--	call	- function to call instead of symbol
local proxy = function(symbol, inherit, gc, lookup, call)
	if type(gc) ~= "string" then
		-- lookup is not needed
		lookup = nil;
	end;
	local o = {
		["symbol"]	= symbol,
		["inherit"]	= inherit,
		["gc"]		= gc,
		["lookup"]	= lookup,
	};
	return setmetatable(o, { ["__call"] = call });
end;
Header.proxy = proxy;
-- }}} Header.proxy()

-- {{{ Header.proxify(...) - proxify dynamic symbol if needed
--	symbol	- dynamic symbol or any reference
--	proto	- function prototype (table from header)
--	lib	- library table with all long named function for GC lookups
local proxify = function(symbol, proto, lib)
	local gc = proto["_gc"];
	local inherit = proto["_inherit"];
	local root = lib[""];
	if not root then
		root = {};
		lib[""] = root;
	end;
	if inherit then
		-- proxy with a constructor function
		local api = {};
		for i = 1, #inherit, 1 do
			local v = inherit[i];
			if type(v) == "table" then
				table.insert(api, v);
			else
				local t = lib[v];
				if not t then
					t = {};
					lib[v] = t;
				end;
				table.insert(api, t);
			end;
		end;
		return proxy(symbol, api, gc, root, proxy_call);
	end;
	if gc ~= nil then
		-- proxy with a string function
		return proxy(symbol, nil, gc, root, proxy_string);
	end;
	-- no need in proxy
	return symbol;
end;
Header.proxify = proxify;
-- }}} Header.proxify()

-- {{{ Header.normalize(...) - normalize header's chunk metadata
--	opt	- metadata for the header's chunk
local normalize = function(opt)
	if not opt then opt = {} end;
	local glue = opt["glue"];
	if not glue then glue = "_" end;
	local pref = opt["prefix"];
	local hier;
	if pref then
		if type(pref) == "string" then pref = { pref } end;
		hier = pref;
		pref = table.concat(pref, glue);
	else
		pref = "";
		hier = {};
	end;
	return {
		["prefix"]	= pref;	-- "curl_easy"
		["glue"]	= glue;	-- "_"
		["hierarchy"]	= hier;	-- { "curl", "easy" }
	};
end;
Header.normalize = normalize;
-- }}} Header.normalize()

-- {{{ Header.put_symbol(...) - place symbol to the library table
--	symbol	- loaded symbol (any reference)
--	lib	- library table
--	opt	- normalized header options
--	name	- shortest name of the function
local put_symbol = function(symbol, lib, opt, name)
	local left = {};
	for i = 1, #(opt["hierarchy"]), 1 do left[i] = opt["hierarchy"][i] end;
	repeat
		-- place symbol to the current hierarchy level
		local tbl = table.concat(left, opt["glue"]);
		if not lib[tbl] then lib[tbl] = {} end;
		tbl = lib[tbl];
		tbl[name] = symbol;
		-- decrease hierarchy level
		tbl = left[#left];
		if not tbl then break end;
		table.remove(left);
		name = tbl .. (opt["glue"]) .. name;
	until #(opt["hierarchy"]) < 1;
end;
-- export it with normalization included
Header.put_symbol = function(symbol, lib, opt, name)
	return put_symbol(symbol, lib, normalize(opt), name);
end;
-- }}} Header.put_symbol()

-- {{{ Header.find_header(...)	- find table in the header by prefix
--	header	- full header table
--	prefix	- prefix of header chunk to look for
local find_header = function(header, prefix)
	for i = 1, #header, 1 do
		local v = header[i];
		local opt = v["_dlffi"];
		local pref;
		if opt then pref = opt["prefix"] end;
		if not pref then
			pref = "";
		elseif type(pref) == "table" then
			local glue = pref["glue"];
			if not glue then glue = "_" end;
			pref = table.concat(pref, glue);
		end;
		if pref == prefix then return v end;
	end;
end;
Header.find_header = find_header;
-- }}} Header.find_header()

-- {{{ Header.loadlib(...)
--	header	- header table
--	lib	- target library table (may be nil)
local loadlib = function (header, lib)
	if not lib then lib = {} end;
	local meta = header["_dlffi"];
	if not meta then return nil, "No header metadata found" end;
	local libs = meta["lib"];
	if type(libs) == "string" then libs = { libs } end;
	for i = 1, #header, 1 do
		local cur = header[i];
		local opt = normalize(cur["_dlffi"]);
		for j = 1, #cur, 1 do
			local v = cur[j];
			-- load symbol with it's original name
			local name = v[1];
			if #(opt["prefix"]) > 0 then
				v[1] = (opt["prefix"]) ..
					(opt["glue"]) .. v[1];
			else
				v[1] = (opt["prefix"]) .. v[1];
			end;
			local f;
			-- probe all given libraries
			for i = 1, #libs, 1 do
				f = dl.load(libs[i], table.unpack(v));
				if f then break end;
			end;
			if not f then
				return nil,
					"Invalid prototype " ..
					"or symbol not found: " ..
					tostring(v[1]);
			end;
			-- name of function was previously modified, restore it back
			v[1] = name;
			-- make proxy function if needed
			f = proxify(f, v, lib, opt);
			-- place symbol in tables according to given hierarchy
			put_symbol(f, lib, opt, name);
		end;
	end;
	return lib;
end;
Header.loadlib = loadlib;
-- }}} Header.loadlib()
-- }}} Header

-- {{{ empty(...) - is object is empty
--	obj	- object to test
local empty;
empty = function (obj)
	if not obj then return true end;
	if obj == dl.NULL then return true end;
	if type(obj) == "table" then return empty(obj._val) end;
	return false;
end;
-- }}} empty();

-- {{{ destroy(...)
--	obj	- object to destroy
--	call	- whether call gc
local function destroy(obj, call)
	if type(obj) ~= "table" then return end;
	local mt = obj._gc;
	if not mt then return end;
	mt = getmetatable(mt);
	if not mt then return end;
	if call then
		local gc = mt.__gc;
		if not gc then return end;
		gc();
	end;
	mt.__gc = nil;
	obj._gc = nil;
	setmetatable(obj, {});
	obj._val = nil;
end;
-- }}} destroy()

dl.Dlffi = Dlffi;
dl.Dlffi_t = Dlffi_t;
dl.cast_table = cast_table;
dl.Header = Header;
dl.empty = empty;
dl.destroy = destroy;
return dl;

