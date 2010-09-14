#!/usr/bin/env lua

--[[
	assume the MySQL server is running on localhost:3306
	and user "test" with password "mypas" is granted any
	privileges on database "test";
	feel free to modify real_connect()'s parameters to
	fit the sample code for your very case;
--]]

local dl = require("liblua_dlffi");
require("mysql");

function main()
	-- run a constructor
	local sql = Mysql:new(true);
	assert(sql ~= nil, "cannot initialize ODBC");
--[[
-- setrlimit on RLIMIT_AS
for _, v in ipairs { "setrlimit", "getrlimit" } do
	_G[v] = dl.load("libc.so.6", v, dl.ffi_type_sint,
		{ dl.ffi_type_sint, dl.ffi_type_pointer }
	);
	assert(_G[v] ~= nil, "Unable to load " .. v);
end;
_struct_rlimit = { dl.ffi_type_ulong, dl.ffi_type_ulong };
struct_rlimit = dl.type_init(_struct_rlimit);
assert(struct_rlimit ~= nil, "Cannot initialize type");
local buf = dl.dlffi_Pointer(dl.sizeof(struct_rlimit), true);
assert(buf ~= nil, "buffer malloc() failed");
dl.type_element(buf, struct_rlimit, 1, 5267455);
dl.type_element(buf, struct_rlimit, 2, 5267455);
local r = setrlimit(9, buf);
assert(tonumber(r) == 0, "setrlimit() failed");
local r = getrlimit(9, buf);
assert(tonumber(r) == 0, "getrlimit() failed");
print("soft:", dl.type_element(buf, struct_rlimit, 1));
print("hard:", dl.type_element(buf, struct_rlimit, 2));
dl.type_free(struct_rlimit);
--]]
	-- connect to a test server
	local con = sql:real_connect(
		"localhost",
		"test",
		"mypas",
		"test",
		3306,
		dl.NULL,
		0
	);
	assert(con ~= dl.NULL, "unable to connect");
	-- create a `sample` table
	local que = [=[
		CREATE TABLE IF NOT EXISTS `sample` (
			`id` INT (11) auto_increment,
			`name` TINYTEXT NOT NULL,
			`misc` MEDIUMTEXT NOT NULL,
			PRIMARY KEY(`id`)
			)
			ENGINE=InnoDB
			DEFAULT CHARSET=utf8
			COLLATE=utf8_unicode_ci
			COMMENT='a sample DB'
	]=]
	local r = sql:query(que);
	assert(r ~= nil, "Unable to create `sample` table");
	-- truncate it in case it has been here
	local que = [=[TRUNCATE `sample`]=];
	local r = sql:query(que);
	assert(
		r ~= nil,
		"TRUNCATE `sample` failed with " .. tostring(r)
	);
	-- fill the `sample` table with 1000 records
	for i = 1, 1000, 1 do
		-- tag `name` with \0 to emulate binary data
		local que = [=[
			INSERT INTO `sample` SET
			`name` = "]=] ..
				--[[ nil asserting is omitted here
					in sake of simplicity
				--]]
				sql:real_escape_string(
					"id_" ..
					tostring(i) ..
					"\0"
				) ..
			[=[", `misc` = "]=] ..
				--[[ nil asserting is omitted here
					in sake of simplicity
				--]]
				sql:real_escape_string(
					"comment for id_" ..
					tostring(i)
				) ..
			[=["
		]=];
		local r = sql:query(que);
		assert(
			r ~= nil,
			"INSERT #" .. tostring(i) ..
			" failed with " .. tostring(r)
		);
	end;
	-- read the data back
	local que = [=[
		SELECT `id`, `name`, `misc`
		FROM `sample`
		ORDER BY `id`
	]=];
	local res = sql:query(que, true);
	assert(
		res ~= nil,
		"Failed to read `sample` table with " ..
			tostring(r)
	);
	-- read all records
	repeat
		local r = res:fetch_assoc();
		--[[
		mysql.fetch_assoc() will return nil on error or
		if no more records are available
		--]]
		if not r then break end;
		-- replace \0 with something printable
		r["name"] = string.gsub(r["name"], "%z", "\\0");
		print(r["id"], r["name"], r["misc"]);
	until false;
end;

main();

