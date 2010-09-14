dl = require("liblua_dlffi");

Dlffi = {};

function Dlffi:new(api, init, gc, spec)
	--[[
		api	- library API
		init	- constructor: bool function(self)
		gc	- destructor: void function(self)
		spec	- list of special functions
	--]]
	local o = {};
	o._val = init;
	if gc ~= nil then
		t = getmetatable(gc);
		if t ~= nil then
			if t.__call ~= nil then
				t = "function";
			else t = nil end;
		else t = type(gc);
		end;
		if t ~= "function" then
			return nil, "GC must be a function";
		end;
		o._gc = newproxy(true);
		getmetatable(o._gc).__gc = function()
			local val = o._val;
			if val ~= nil and val ~= dl.NULL then gc(val) end;
		end;
	end;
	setmetatable(o, { __index = function (t, v)
		local f = self[v];
		if f then return f end;
		local f = api[v];
		if f == nil then return end;
		local val = rawget(o, "_val");
		if val == nil or val == dl.NULL then return end;
		return function(...)
			return f(val, select(2, ...));
		end;
	end });
	return o;
end;

function Dlffi:type_init()
end;

