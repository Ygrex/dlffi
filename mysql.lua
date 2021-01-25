local LIBMYSQL = "libmysqlclient.so";

-- make 5.1 and 5.2 compatibility
local unpack = unpack;
if not unpack then unpack = table.unpack end;

local dl = require("dlffi");

-- {{{ load library
local mysql_t = dl.Dlffi_t:new(
	"MYSQL_FIELD",
	{
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
	}
);

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
{
	"autocommit",
	dl.ffi_type_sint,
	{
		dl.ffi_type_pointer,	-- obj
		dl.ffi_type_sint,	-- mode
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
	["use_result"] = mysql.free_result,
	["store_result"] = mysql.free_result,
}

-- }}} load library

local Mysql = { _type = "object" }

-- {{{ Mysql:new(bool) -- constructor
--	server_end - if mysql_server_end() must be called by GC
function Mysql:new(server_end)
	local gc = mysql.close;
	if server_end then
		gc = function(o)
			mysql.close(o);
			mysql.server_end();
		end;
	end;
	return dl.Dlffi:new(
		{ Mysql, mysql},
		mysql.init(dl.NULL),
		gc,
		mysql_bind
	);
end;
-- }}} Mysql:new

-- {{{ MYSQL_RES * Mysql:query(char * [, bool] )
--[[
	override mysql_query combining both mysql_real_query()
	and mysql_store_result()
	return the result value of the later function
	stmt	- query statement
	bool	- whether to use mysql_use_result() instead
--]]
function Mysql:query(stmt, use_result)
	local malloc = "memory allocation error";
	local r, e = self:real_query(stmt, #stmt);
	if not r then return nil, e and e or malloc end;
	if tonumber(r) ~= 0 then
		return nil, "mysql_real_query() returned " .. tostring(r);
	end;
	if (use_result) then
		r, e = self:use_result();
		if not r then
			-- mysql_use_result must always return non-NULL
			-- if no error
			return nil, e;
		end;
	else
		r, e = self:store_result();
		if not r then
			-- r is empty if mysql_store_result's returned NULL
			-- it is not necessary an error
			return;
		end;
	end;
	-- something has been returned
	return r;
end;
-- }}} Mysql:query

-- {{{ char * Mysql:real_escape_string(char *)
function Mysql:real_escape_string(stmt)
	-- override mysql_real_escape_string()
	if not stmt then return "" end;
	local buf = dl.dlffi_Pointer(1 + 2 * #stmt, true);
	if buf == nil then return nil, "dlffi_Pointer() failed" end;
	local r = mysql.real_escape_string(
		self,
		buf,
		stmt,
		#stmt
	);
	if r == nil then return nil, "mysql_real_escape_string() failed" end;
	return buf:tostring(tonumber(r));
end;
-- }}} Mysql:real_escape_string

-- {{{ Mysql:fetch_assoc()
function Mysql:fetch_assoc()
	-- self envelops (MYSQL_RES *) here!
	-- get the row firstly
	local row = dl.dlffi_Pointer(self:fetch_row());
	if not row then return nil, "mysql_fetch_row() failed" end;
	-- get the number of fields in the record
	local num = self:num_fields();
	if num == nil then return nil, "mysql_num_fields() failed" end;
	num = tonumber(num);
	-- get columns from the record
	local col = {};
	local fields = dl.dlffi_Pointer(self:fetch_fields());
	if not fields then return nil, "mysql_fetch_fields() failed" end;
	for i = 1, num, 1 do
		local struct = fields:index(i, mysql_t["MYSQL_FIELD"]);
		if not struct then
			return nil,
				[[Error occured when accessing ]] ..
				[[MYSQL_FIELD's element #]] ..
				tostring(i);
		end;
		local name = dl.dlffi_Pointer(
			dl.type_element(
				struct,
				mysql_t["MYSQL_FIELD"],
				1
			)
		);
		if name == nil then
			return nil,
				[[Error occured when accessing ]] ..
				[["name" property of ]] ..
				[[MYSQL_FIELD's element #]] ..
				tostring(i);
		end;
		-- the column name is known here, remember it
		col[i] = name:tostring();
	end;
	-- fetch fields' lengths
	local lengths = dl.dlffi_Pointer(self:fetch_lengths());
	if not lengths then return nil, "mysql_fetch_lengths() failed" end;
	local value = {};
	-- iterate through columns
	for i = 1, num, 1 do
		-- length of the current field
		local len = lengths:index(i, dl.ffi_type_ulong);
		if not len then
			return nil,
				[[Error occured when accessing ]] ..
				[[length of the field #]] ..
				tostring(i);
		end;
		-- get the field value
		local r = row:index(i);
		if r == nil then
			return nil,
				[[Error occured when accessing ]] ..
				[[value of the field #]] ..
				tostring(i);
		end;
		-- remember the field's value
		value[col[i]] = r:tostring(len);
	end;
	-- here "value" is an associative array or an empty table
	return value;
end;
-- }}} Mysql:fetch_assoc

return { ["Mysql"] = Mysql, ["mysql_t"] = mysql_t, ["dl"] = dl, ["mysql"] = mysql };

