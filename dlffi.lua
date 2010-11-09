local dl = require("liblua_dlffi");

local Dlffi = {};

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
			if val ~= nil and val ~= dl.NULL then gc(val) end;
		end;
	end;
	setmetatable(o, { __index = function (t, v)
		local _type, f;
		-- find table with the requested key
		for i = 1, #api, 1 do
			f = rawget(api[i], v);
			if f ~= nil then
				_type = rawget(api[i], "_type");
				break;
			end;
		end;
		if f == nil then
			-- nothing found
			return;
		end;
		if not is_callable(f) then
			-- some property requested
			return f;
		end;
		-- some method requested
		local constructor = spec[v]; -- if the method is a constructor
		-- get it's GC
		local gc = is_callable(constructor) and constructor or nil;
		-- construct appropriate proxy function
		return function(obj, ...)
			if not _type then
				-- function expects raw context (e.g. userdata)
				if type(obj) == "table" then
					-- but Dlffi object specified
					obj = rawget(t, "_val");
				end
			end;
			if constructor then
				-- construct new object
				return self:new(
					api,
					f(obj, ...),
					gc,
					spec
				);
			end;
			if obj == dl.NULL then
				-- uninitialized/invalid context
				return;
			end;
			-- execute the function
			return f(obj, ...);
		end;
	end });
	return o;
end;

local Dlffi_t = {}; -- types container

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

dl.Dlffi = Dlffi;
dl.Dlffi_t = Dlffi_t;
return dl;

