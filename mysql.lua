local LIBC = "libc.so.6";
local LIBMYSQL = "libmysqlclient.so.16";

local dl = require("liblua_dlffi");
assert(dl ~= nil, "unable to load liblua_dlffi");

-- {{{ load library
mysql_t = {
	_MYSQL_FIELD = {
		dl.ffi_type_pointer,	-- char *name
		dl.ffi_type_pointer,	-- char *org_name
		dl.ffi_type_pointer,	-- char *table
		dl.ffi_type_pointer,	-- char *org_table
		dl.ffi_type_pointer,	-- char *db
		dl.ffi_type_pointer,	-- char *catalog
		dl.ffi_type_pointer,	-- char *def
		dl.ffi_type_ulong,	-- unsigned long length
		dl.ffi_type_ulong,	-- unsigned long max_length
		dl.ffi_type_uint,	-- unsigned int name_length
		dl.ffi_type_uint,	-- unsigned int org_name_length
		dl.ffi_type_uint,	-- unsigned int table_length
		dl.ffi_type_uint,	-- unsigned int org_table_length
		dl.ffi_type_uint,	-- unsigned int db_length
		dl.ffi_type_uint,	-- unsigned int catalog_length
		dl.ffi_type_uint,	-- unsigned int def_length
		dl.ffi_type_uint,	-- unsigned int flags
		dl.ffi_type_uint,	-- unsigned int decimals
		dl.ffi_type_uint,	-- unsigned int charsetnr
		dl.ffi_type_uint,	-- enum enum_field_types type
		dl.ffi_type_pointer,	-- void *extension
	},
}
mysql_t.MYSQL_FIELD = dl.type_init(mysql_t._MYSQL_FIELD);

local mysql = {
{
	"init",
	dl.ffi_type_pointer,
	{ dl.ffi_type_pointer }
},
{
	"close",
	dl.ffi_type_void,
	{ dl.ffi_type_pointer }
},
{
	"real_connect",
	dl.ffi_type_pointer,
	{
		dl.ffi_type_pointer,	-- obj
		dl.ffi_type_pointer,	-- host
		dl.ffi_type_pointer,	-- user
		dl.ffi_type_pointer,	-- passwd
		dl.ffi_type_pointer,	-- db
		dl.ffi_type_sint,	-- port
		dl.ffi_type_pointer,	-- unix_socket
		dl.ffi_type_ulong,	-- client_flag
	}
},
{
	"real_query",
	dl.ffi_type_sint,
	{
		dl.ffi_type_pointer,	-- obj
		dl.ffi_type_pointer,	-- statement
		dl.ffi_type_ulong,	-- length
	}
},
{
	"real_escape_string",
	dl.ffi_type_ulong,
	{
		dl.ffi_type_pointer,	-- obj
		dl.ffi_type_pointer,	-- to
		dl.ffi_type_pointer,	-- from
		dl.ffi_type_ulong,	-- length
	}
},
{
	"use_result",
	dl.ffi_type_pointer,
	{
		dl.ffi_type_pointer,	-- obj
	}
},
{
	"store_result",
	dl.ffi_type_pointer,
	{
		dl.ffi_type_pointer,	-- obj
	}
},
{
	"free_result",
	dl.ffi_type_void,
	{
		dl.ffi_type_pointer,	-- obj
	}
},
{
	"num_fields",
	dl.ffi_type_uint,
	{
		dl.ffi_type_pointer,	-- obj
	}
},
{
	"affected_rows",
	dl.ffi_type_ulong,
	{
		dl.ffi_type_pointer,	-- obj
	}
},
{
	"insert_id",
	dl.ffi_type_ulong,
	{
		dl.ffi_type_pointer,	-- obj
	}
},
{
	"num_rows",
	dl.ffi_type_ulong,
	{
		dl.ffi_type_pointer,	-- obj
	}
},
{
	"field_count",
	dl.ffi_type_uint,
	{
		dl.ffi_type_pointer,	-- obj
	}
},
{
	"fetch_row",
	dl.ffi_type_pointer,
	{
		dl.ffi_type_pointer,	-- res
	}
},
{
	"fetch_fields",
	dl.ffi_type_pointer,
	{
		dl.ffi_type_pointer,	-- res
	}
},
{
	"server_end",
	dl.ffi_type_void,
	{ }
},
{
	"error",
	dl.ffi_type_pointer,
	{
		dl.ffi_type_pointer,	-- obj
	},
	true
},
{
	"fetch_lengths",
	dl.ffi_type_pointer,
	{
		dl.ffi_type_pointer,	-- obj
	}
},
}

for _, v in ipairs(mysql) do
	local tmp = v[1];
	v[1] = "mysql_" .. tmp;
	local f, e = dl.load(LIBMYSQL, unpack(v));
	assert(f, e and e or "malloc() failed");
	v[1] = tmp;
	mysql[v[1]] = f;
end;

-- these functions return sub-objects
local mysql_bind = {
	["use_result"] = true,
	["store_result"] = true,
}

-- }}} load library

Mysql = {};

-- {{{ Mysql:new -- constructor
function Mysql:new(server_end)
	--[[
	server_end - if true, then mysql_library_end()
		will be executed in __gc;
		also, mysql specific types will be deallocated;
	--]]
	local o = {
		gc = newproxy(true),
		sql = mysql.init(dl.NULL),
	};
	if not o.gc or not o.sql then return nil end;
	local function meta_sql(t, v)
		local func = mysql[v];
		if func == nil then return nil end;
		if mysql_bind[v] ~= nil then
			return function(...)
				-- sub-object will be returned
				local obj = {};
				obj.val = func(
					t.sql,
					select(2, ...)
				);
				return setmetatable(obj, {
					__index = meta_sql
				});
			end;
		else
			if t.val == nil then
				-- use the main connector
				return function(...)
					return func(
						t.sql,
						select(2, ...)
					);
				end;
			else
				-- use sub-object
				return function(...)
					return func(
						t.val,
						select(2, ...)
					);
				end;
			end;
		end;
	end;
	setmetatable(o, {
		__index = function (t, v)
			local f = rawget(t, v);
			if f then return f end;
			local f = self[v];
			if f then return f end;
			return meta_sql(t, v);
		end
	});
	o.purge = server_end;
	getmetatable(o.gc).__gc = function ()
		if o.sql then
			mysql.close(o.sql);
			o.sql = nil;
		end;
		if o.purge then o:library_end() end;
	end;
	return o;
end;
-- }}}

-- {{{ Mysql:real_escape_string(stmt)
function Mysql:real_escape_string(stmt)
	if stmt == nil then return "" end;
	local buf = dl.dlffi_Pointer(1 + 2 * #stmt, true);
	if buf == nil then return end;
	local r = mysql.real_escape_string(
		self.sql,
		buf,
		stmt,
		#stmt
	);
	if r == nil then return nil end;
	return buf:tostring(tonumber(r));
end;
-- }}} Mysql:real_escape_string

-- {{{ Mysql:query(stmt[, use_result])
-- call mysql_use_result() if the second parameter is true
-- otherwise mysql_store_result()
function Mysql:query(stmt, use_result)
	local malloc = "memory allocation error";
	local r, e = self:real_query(stmt, #stmt);
	if not r then return nil, e and e or malloc end;
	if tonumber(r) ~= 0 then
		return nil, "mysql_real_query() == " .. tostring(r);
	end;
	local res, e;
	if use_result then
		res, e = self:use_result();
	else
		res, e = self:store_result();
	end;
	if not res then return nil, e and e or malloc end;
	if res == dl.NULL then return nil, "mysql_use_result() == NULL" end;
	local ptr, e = dl.dlffi_Pointer(res.val);
	if not ptr then
		res:free_result();
		return nil, e and e or malloc;
	end;
	ptr:set_gc(function () res:free_result() end);
	res.val = ptr;
	return res;
end;
-- }}} Mysql:query

-- {{{ Mysql:library_end(Mysql)
function Mysql:library_end()
	mysql.server_end();
	for k, v in pairs(mysql_t) do
		if type(v) == "userdata" then
			dl.type_free(v);
			mysql_t[k] = nil;
		end;
	end;
end;
-- }}} Mysql:library_end

-- {{{ mysql_fetch_assoc(MYSQL_RES *)
function mysql.fetch_assoc(res)
	local num = mysql.num_fields(res);
	if num == nil then
		return nil, "mysql_num_fields() failed";
	end;
	num = tonumber(num);
	local col = {};
	local fields = mysql.fetch_fields(res);
	if fields == dl.NULL then
		return nil, "mysql_fetch_fields() failed";
	end;
	fields = dl.dlffi_Pointer(fields);
	for i = 1, num, 1 do
		local struct = fields:index(i, mysql_t.MYSQL_FIELD);
		if struct == nil then
			return nil,
				[=[error occured when accessing ]=] ..
				[=[MYSQL_FIELD's element #]=] ..
				tostring(i);
		end;
		local name = dl.type_element(
			struct,
			mysql_t.MYSQL_FIELD,
			1
		);
		col[i] = dl.dlffi_Pointer(name):tostring();
	end;
	local row = mysql.fetch_row(res);
	if row == dl.NULL then
		return nil, "mysql_fetch_row() failed";
	end;
	row = dl.dlffi_Pointer(row);
	local lengths = mysql.fetch_lengths(res);
	if lengths == nil or lengths == dl.NULL then
		return nil, "mysql_fetch_lengths() failed";
	end;
	lengths = dl.dlffi_Pointer(lengths);
	local value = {};
	for i = 1, num, 1 do
		local len = lengths:index(i, dl.ffi_type_ulong);
		if len == nil then
			return nil,
				"error occured when accessing " ..
				"length of the field #" ..
				tostring(i);
		end;
		local r = row:index(i);
		if r == nil then
			return nil,
				"error occured when accessing " ..
				"value of the field #" ..
				tostring(i);
		end;
		value[col[i]] = r:tostring(len);
	end;
	return value;
end;
-- }}} mysql_fetch_assoc(MYSQL_RES *)

