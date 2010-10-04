#define _GNU_SOURCE
#include <features.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <ffi.h>
#include <endian.h>
#include <pthread.h>

/* {{{ struct dlffi_Pointer */
typedef struct dlffi_Pointer {
	void *pointer;
	int gc;
	int ref;
} dlffi_Pointer;
/* }}} struct dlffi_Pointer */

/* {{{ struct dlffi_Function */
typedef struct dlffi_Function {
	void *dlhdl;
	void *dlsym;
	ffi_cif cif;
	ffi_type **types;
	ffi_type *type;
	void *ret;
	int str;
	int ref;
	ffi_closure *closure;
	lua_State *L;
} dlffi_Function;
/* }}} dlffi_Function */

/* {{{ dlffi_Pointer *dlffi_check_Pointer(lua_State *L, int idx)
	check if the indexed value is of (void **)
*/
inline dlffi_Pointer *dlffi_check_Pointer(lua_State *L, int idx) {
	return (dlffi_Pointer *)luaL_checkudata(L, idx, "dlffi_Pointer");
}
/* }}} dlffi_check_Pointer */

/* {{{ int type_push(lua_State *L, void *o, ffi_type *t) */
int type_push(lua_State *L, void *o, ffi_type *t)
{
	if (lua_checkstack(L, 1) == 0) return 0;
	if (t == &ffi_type_pointer) {
		lua_pushlightuserdata(L, *(void **)o);
	} else if (t == &ffi_type_void) {
		lua_pushnil(L);
	} else if (t == &ffi_type_float) {
		lua_pushnumber(L, *(float *)o);
	} else if (t == &ffi_type_double) {
		lua_pushnumber(L, *(double *)o);
	} else if (t == &ffi_type_longdouble) {
		lua_pushnumber(L, *(long double *)o);
	} else if (
		t == &ffi_type_slong ||
		t == &ffi_type_ulong
	) {
		lua_pushinteger(L, *(long *)o);
	} else if (
		t == &ffi_type_sint ||
		t == &ffi_type_uint
	) {
		lua_pushinteger(L, *(int *)o);
	} else if (
		t == &ffi_type_schar ||
		t == &ffi_type_uchar
	) {
		lua_pushinteger(L, *(char *)o);
	} else if (
		t == &ffi_type_sshort ||
		t == &ffi_type_ushort
	) {
		lua_pushinteger(L, *(short *)o);
	} else {
		// unknown structure, create dlffi_Pointer
		dlffi_Pointer *p = (dlffi_Pointer *)
			lua_newuserdata(L, sizeof(dlffi_Pointer));
		if (!p) return 0;
		p->pointer = o;
		p->gc = 0;
		p->ref = LUA_REFNIL;
		luaL_getmetatable(L, "dlffi_Pointer");
		lua_setmetatable(L, -2);
	}
	return 1;
}
/* }}} type_push */

// {{{ write_value(void *dst, void *src, size_t dst_size, size_t src_size)
inline void write_value(
	void *dst, void *src, size_t dst_size, size_t src_size
) {
	bzero(dst, dst_size);
	if (dst_size < src_size) {
		if (BYTE_ORDER == LITTLE_ENDIAN) {
			memcpy(dst, src, dst_size);
		} else memcpy(dst, src + (src_size - dst_size), dst_size);
	} else {
		if (BYTE_ORDER == LITTLE_ENDIAN) {
			memcpy(dst, src, src_size);
		} else memcpy(dst + (dst_size - src_size), src, src_size);
	}
}
// }}} write_value

/* {{{ type_write(L, int idx, ffi_type *type, void *dst) */
inline void *type_write(lua_State *L, int idx, ffi_type *type, void *dst)
{
	void *u = NULL;
	size_t len;
	// supported LUA types
	int val_i;
	lua_Integer val_I;
	void *val_u;
	lua_Number val_n;
	// guess the type of the given argument
	switch (lua_type(L, idx)) {
	case LUA_TBOOLEAN:
		val_i = lua_toboolean(L, idx);
		len = sizeof(int);
		u = &val_i;
		break;
	case LUA_TLIGHTUSERDATA:
		if (type != &ffi_type_pointer) return NULL;
		val_u = lua_touserdata(L, idx);
		len = sizeof(void *);
		u = &val_u;
		break;
	case LUA_TUSERDATA:
		if ( lua_checkstack(L, 2) == 0 ) return NULL;
		if (lua_getmetatable(L, idx)) {
			lua_getfield(L, LUA_REGISTRYINDEX, "dlffi_Function");
			if (lua_rawequal(L, -1, -2)) {
			// dlffi_Function
			val_u = luaL_checkudata(L, idx, "dlffi_Function");
			val_u = ((dlffi_Function *)val_u);
			if (((dlffi_Function *)val_u)->ref != LUA_REFNIL) {
				// dlffi_Function referent
				val_u = *( FFI_FN(
					((dlffi_Function *)val_u)->dlsym
				) );
			} else {
				// empty dlffi_Function
				val_u = ((dlffi_Function *)val_u)->dlsym;
			}
			} else {
			// dlffi_Pointer
			val_u = (dlffi_check_Pointer(L, idx))->pointer;
			}
			lua_pop(L, 2);
		} else return NULL;
		len = sizeof(void *);
		u = &val_u;
		break;
	case LUA_TNUMBER:
		if (
			type == &ffi_type_float ||
			type == &ffi_type_double ||
			type == &ffi_type_longdouble
		) {
			// floating point
			val_n = lua_tonumber(L, idx);
			len = sizeof(lua_Number);
			u = &val_n;
		} else {
			// integer
			val_I = lua_tointeger(L, idx);
			len = sizeof(lua_Integer);
			u = &val_I;
		}
		break;
	case LUA_TSTRING:
		if (type != &ffi_type_pointer) return NULL;
		size_t l;
		char *c = (char *)lua_tolstring(L, idx, &l);
		val_u = malloc(l + 1);
		if (!val_u) return NULL;
		memcpy(val_u, c, l + 1);
		len = sizeof(void *);
		u = &val_u;
		break;
	default:
		return NULL;
	}
	write_value(dst, u, type->size, len);
	return u;
}
/* }}} type_write */

/* {{{ ffi_type *dlffi_type_init(int size) */
/* initialize a new type of function return value, specified by a size */
/* return pointer to a new type or nothing on error */
static int l_dlffi_type_init(lua_State *L) {
	ffi_type *o = malloc(sizeof(ffi_type));
	if (o == NULL) return 0;
	// prepare the structure
	luaL_checktype(L, 1, LUA_TTABLE);
	size_t l = lua_objlen(L, 1);
	o->size = o->alignment = 0;
	o->type = FFI_TYPE_STRUCT;
	o->elements = calloc(l + 1, sizeof(ffi_type *));
	if (! o->elements) return 0;
	o->elements[l] = NULL;
	// read the table
	size_t i;
	if (lua_checkstack(L, 4) == 0) return 0;
	for (i = 0; i < l; i++) {
		lua_pushinteger(L, (lua_Integer)i + 1);
		lua_gettable(L, 1);
		luaL_checktype(L, -1, LUA_TLIGHTUSERDATA);
		o->elements[i] = lua_touserdata(L, -1);
		if (! o->elements[i]) {
			lua_pushnil(L);
			lua_pushfstring(L,
				"Incorrect FFI type #%d",
				(lua_Integer)i + 1
			);
			return 2;
		}
		lua_pop(L, 1);
	}
	// init the type
	ffi_cif cif;
	ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 0, o, NULL);
	lua_pushlightuserdata(L, o);
	return 1;
}
/* }}} dlffi_type_init */

/* {{{ void dlffi_type_free(ffi_type *) */
static int l_dlffi_type_free(lua_State *L) {
	luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
	ffi_type *o = lua_touserdata(L, 1);
	if (o) {
		free(o->elements);
		free(o);
	}
	return 0;
}
/* }}} dlffi_type_free */

/* {{{ size_t type_offset(ffi_type *, size_t n) */
size_t type_offset(ffi_type *o, size_t n)
{
	if (o->type != FFI_TYPE_STRUCT) return 0;
	size_t offset = 0;
	size_t i;
	for (i = 0; i < n; i++) {
		ffi_type *e = o->elements[i];
		offset += e->size + (
			(
			(size_t)e->alignment +
				(
				(offset - 1)
				&
				~((size_t)e->alignment - 1)
				)
			) - offset
		);
	}
	offset -= o->elements[n - 1]->size;
	if (offset >= o->size) return 0;
	return offset;
}
/* }}} type_offset */

/* {{{ void dlffi_type_offset(ffi_type *, lua_Integer n) */
static int l_dlffi_type_offset(lua_State *L) {
	luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
	ffi_type *o = lua_touserdata(L, 1);
	if (!o) return 0;
	lua_Integer n = luaL_checkinteger(L, 2);
	if (n < 1) return 0;
	if (lua_checkstack(L, 1) == 0) return 0;
	lua_pushinteger(L, (lua_Integer)type_offset(o, (size_t)n));
	return 1;
}
/* }}} dlffi_type_offset */

/* {{{ void dlffi_type_element(void *o, ffi_type *, lua_Integer idx) */
static int l_dlffi_type_element(lua_State *L) {
	inline int report(const char *msg) {
		if (lua_checkstack(L, 2) == 0) return 0;
		lua_pushnil(L);
		lua_pushstring(L, msg);
		return 2;
	}
	void *p;
	switch (lua_type(L, 1)) {
	case LUA_TLIGHTUSERDATA:
		p = lua_touserdata(L, 1);
		break;
	case LUA_TUSERDATA:
		p = (dlffi_check_Pointer(L, 1))->pointer;
		break;
	default:
		return report("pointer expected");
	}
	ffi_type *t = lua_touserdata(L, 2);
	if (t->type != FFI_TYPE_STRUCT)
		return report("FFI type is not a structure");
	lua_Integer n = lua_tointeger(L, 3);
	if (n < 1) return report("invalid element index");
	if (lua_gettop(L) < 4) {
		return type_push(L, p + type_offset(t, n), t->elements[n-1]);
	} else {
		void *u = type_write(
			L,
			4,
			t->elements[n - 1],
			p + type_offset(t, n)
		);
		if (lua_checkstack(L, 1) == 0) return 0;
		lua_pushboolean(L, (u == NULL) ? 0 : 1);
		return 1;
	}
}
/* }}} dlffi_type_element */

// {{{ void dlffi_closure_run(ffi_cif *, void *, void **, dlffi_Function *)
static void dlffi_closure_run(
	ffi_cif *cif,
	void *ret,
	void **argv,
	dlffi_Function *o
) {
	int top = lua_gettop(o->L);
	if (lua_checkstack(o->L, 1 + cif->nargs) == 0) return;
	lua_rawgeti(o->L, LUA_REGISTRYINDEX, o->ref);
	unsigned i;
	for (i = 0; i < cif->nargs; i++) {
		void *t = o->cif.arg_types[i];
		if (t == &ffi_type_pointer) {
			lua_pushlightuserdata(o->L, *(void **)(argv[i]));
		} else if (t == &ffi_type_void) {
			lua_pushnil(o->L);
		} else if (t == &ffi_type_float) {
			lua_pushnumber(o->L, *(float *)(argv[i]));
		} else if (t == &ffi_type_double) {
			lua_pushnumber(o->L, *(double *)(argv[i]));
		} else if (t == &ffi_type_longdouble) {
			lua_pushnumber(o->L, *(long double *)(argv[i]));
		} else if (
			t == &ffi_type_slong ||
			t == &ffi_type_ulong
		) {
			lua_pushinteger(o->L, *(long *)(argv[i]));
		} else if (
			t == &ffi_type_sint ||
			t == &ffi_type_uint
		) {
			lua_pushinteger(o->L, *(int *)(argv[i]));
		} else if (
			t == &ffi_type_schar ||
			t == &ffi_type_uchar
		) {
			lua_pushinteger(o->L, *(char *)(argv[i]));
		} else if (
			t == &ffi_type_sshort ||
			t == &ffi_type_ushort
		) {
			lua_pushinteger(o->L, *(short *)(argv[i]));
		} else {
			lua_pushlightuserdata(o->L, argv[i]);
		}
	}
	int r;
	if (o->type == &ffi_type_void)
		r = lua_pcall(o->L, cif->nargs, 0, 0);
	else {
		bzero(ret, o->type->size);
		r = lua_pcall(o->L, cif->nargs, 1, 0);
	}
	if (r == 0) {
		type_write(o->L, -1, o->type, ret);
	}
	lua_settop(o->L, top);
}
// }}} dlffi_closure_run

/* {{{ dlffi_Function *l_dlffi_create(
	void (*function)(),
	ffi_type *rtype,
	ffi_type **argument types
	)
*/
static int l_dlffi_create(lua_State *L) {
	size_t i;
	if (lua_checkstack(L, 5) == 0) return 0;
	dlffi_Function *o = (dlffi_Function *)
		lua_newuserdata(L, sizeof(dlffi_Function));
	if (!o) return 0;
	o->types = NULL;
	o->dlhdl = NULL;
	o->dlsym = NULL;
	o->ret = NULL;
	o->ref = LUA_REFNIL;
	o->closure = NULL;
	/* set the FFI type of a return value */
	o->type = lua_touserdata(L, 2);
	if (! o->type) {
		lua_pushnil(L);
		lua_pushstring(L,
			"Incorrect return value FFI type specified");
		return 2;
	}
	o->str = 0;
	luaL_getmetatable(L, "dlffi_Function");
	lua_setmetatable(L, -2);
	/* iterate through argument FFI types */
	luaL_checktype(L, 3, LUA_TTABLE);
	size_t l = lua_objlen(L, 3);
	o->types = calloc(l + 1, sizeof(ffi_type *));
	if (! o->types) return 0;
	o->types[l] = NULL;
	for (i = 1; i <= l; i++) {
		lua_pushinteger(L, (lua_Integer)i);
		lua_gettable(L, 3);
		o->types[i - 1] = lua_touserdata(L, -1);
		if (! o->types[i-1]) {
			lua_pushnil(L);
			lua_pushfstring(L,
				"Incorrect argment FFI type #%d",
				(lua_Integer)i
			);
			return 2;
		}
		lua_pop(L, 1);
	}
	ffi_status stat = ffi_prep_cif(
		&o->cif,
		FFI_DEFAULT_ABI,
		(unsigned int) l,
		o->type,
		o->types
	);
	if (stat != FFI_OK) {
		lua_pushnil(L);
		lua_pushstring(L, "ffi_prep_cif() failed");
		return 2;
	}
	o->ret = malloc(o->type->size);
	o->closure = ffi_closure_alloc(sizeof(ffi_closure), &(o->dlsym));
	lua_pushvalue(L, 1);
	o->ref = luaL_ref(L, LUA_REGISTRYINDEX);
	o->L = L;
	ffi_prep_closure_loc(
		o->closure,
		&(o->cif),
		(void (*)(ffi_cif *, void *, void **, void *))dlffi_closure_run,
		o,
		o->dlsym
	);
	return 1;
}
/* }}} l_dlffi_create */

/* {{{ dlffi_Function *l_dlffi_load(
	char *library,
	char *function,
	ffi_type *rtype,
	ffi_type **argument types,
	boolean string_function
	)
*/
static int l_dlffi_load(lua_State *L) {
	size_t i;
	if (lua_type(L, 1) == LUA_TFUNCTION) return l_dlffi_create(L);
	const char *lib = luaL_checkstring(L, 1);
	const char *fun = luaL_checkstring(L, 2);
	if (lua_checkstack(L, 5) == 0) return 0;
	/* create the DLFFI structure */
	dlffi_Function *o = (dlffi_Function *)
		lua_newuserdata(L, sizeof(dlffi_Function));
	if (!o) return 0;
	o->types = NULL;
	o->dlhdl = NULL;
	o->dlsym = NULL;
	o->ret = NULL;
	o->ref = LUA_REFNIL;
	if (lua_gettop(L) > 5) {
		o->str = lua_toboolean(L, 5);
	} else o->str = 0;
	luaL_getmetatable(L, "dlffi_Function");
	lua_setmetatable(L, -2);
	if (*lib == 0) {
		o->dlhdl = dlopen(NULL, RTLD_LAZY);
	} else o->dlhdl = dlopen(lib, RTLD_LAZY);
	if (! o->dlhdl) {
		lua_pushnil(L);
		lua_pushfstring(L, "dlopen() failed: %s", dlerror());
		return 2;
	}
	dlerror();
	o->dlsym = dlsym(o->dlhdl, fun);
	char *e;
	if ((e = dlerror()) != NULL) {
		lua_pushnil(L);
		lua_pushfstring(L, "dlsym() failed: %s", e);
		return 2;
	}
	/* set the FFI type of a return value */
	o->type = lua_touserdata(L, 3);
	if (! o->type) {
		lua_pushnil(L);
		lua_pushstring(L,
			"Incorrect return value FFI type specified");
		return 2;
	}
	/* iterate through argument FFI types */
	luaL_checktype(L, 4, LUA_TTABLE);
	size_t l = lua_objlen(L, 4);
	o->types = calloc(l + 1, sizeof(ffi_type *));
	if (! o->types) return 0;
	o->types[l] = NULL;
	for (i = 1; i <= l; i++) {
		lua_pushinteger(L, (lua_Integer)i);
		lua_gettable(L, 4);
		o->types[i - 1] = lua_touserdata(L, -1);
		if (! o->types[i-1]) {
			lua_pushnil(L);
			lua_pushfstring(L,
				"Incorrect argment FFI type #%d",
				(lua_Integer)i
			);
			return 2;
		}
		lua_pop(L, 1);
	}
	ffi_status stat = ffi_prep_cif(
		&o->cif,
		FFI_DEFAULT_ABI,
		l,
		o->type,
		o->types
	);
	if (stat != FFI_OK) {
		lua_pushnil(L);
		lua_pushstring(L, "ffi_prep_cif() failed");
		return 2;
	}
	if (o->type->size < sizeof(ffi_arg))
		o->ret = malloc(sizeof(ffi_arg));
	else o->ret = malloc(o->type->size);
	if (! o->ret) return 0;
	if (o->str) {
		if (o->type != &ffi_type_pointer) {
			o->str = 0;
			lua_pushnil(L);
			lua_pushstring(L,
				"string function must be of ffi_type_pointer"
			);
			return 2;
		}
		*(char **)o->ret = NULL;
	}
	return 1;
}
/* }}} l_dlffi_load */

/* {{{ dlffi_Function *dlffi_check_Function(lua_State *L)
	check if the bottom value is of (dlffi_Function *)
*/
inline dlffi_Function *dlffi_check_Function(lua_State *L) {
	return (dlffi_Function *)luaL_checkudata(L, 1, "dlffi_Function");
}
/* }}} dlffi_check_Function */

/* {{{ const char *dlffi_Function_str(
	dlffi_Function *o,
	int idx
	)
*/
static int dlffi_Function_str(lua_State *L) {
	dlffi_Function *o = dlffi_check_Function(L);
	if (!o) return 0;
	luaL_checktype(L, -1, LUA_TFUNCTION);
	o->ref = luaL_ref(L, LUA_REGISTRYINDEX);
	return 0;
}
/* }}} dlffi_Function_str */

/* {{{ ... dlffi_run(...)
	arguments like in a loaded function
*/
static int dlffi_run(lua_State *L) {
	dlffi_Function *o = dlffi_check_Function(L);
	size_t argc = 0;
	inline int report(const char *msg) {
		if ( lua_checkstack(L, 2) == 0 ) return 0;
		lua_pushnil(L);
		lua_pushstring(L, msg);
		return 2;
	};
	if ( (o->types == NULL) || (o->ret == NULL) )
		return report("function must be loaded first");
	if (o->ref != LUA_REFNIL)
		return report("closure function call not implemented");
	while (o->types[argc]) argc += 1;
	if (argc != (size_t)(lua_gettop(L) - 1)) {
		if ( lua_checkstack(L, 2) == 0 ) return 0;
		lua_pushnil(L);
		lua_pushfstring(L, "passed %d arguments, but %d expected",
			lua_gettop(L) - 2, argc);
		return 2;
	}
	void **argv = calloc(argc + 1, sizeof(void *));
	if (!argv) return 0;
	argv[argc] = NULL;
	inline int raise_error(lua_State *L,
		const char *e,
		size_t argc,
		void **argv
	) {
		if (argv) while (argv[++argc]) {
			if (lua_type(L, argc + 2) == LUA_TSTRING)
				free(*(char **)(argv[argc]));
			free(argv[argc]);
		}
		if (!e) return 0;
		if ( lua_checkstack(L, 2) == 0 ) return 0;
		lua_pushnil(L);
		lua_pushfstring(L, e);
		return 2;
	}
	if (argc) do {
		argc -= 1;
		argv[argc] = malloc(o->types[argc]->size);
		if (!argv[argc]) return raise_error(L, NULL, argc, argv);
		void *u = type_write(
			L, argc + 2, o->types[argc], argv[argc]
		);
		if (u == NULL) {
			free(argv[argc]);
			return raise_error(
				L,
				"error occured processing arguments",
				argc, argv
			);
		}
	} while(argc);
	if (o->str) {
		free(*(char **)o->ret);
		*(char **)o->ret = NULL;
	}
	ffi_call(&(o->cif), o->dlsym, (void *)o->ret, argv);
	if ( o->str && ( *(char **)o->ret != NULL ) ) {
		*(char **)o->ret = strdup(*(const char **)o->ret);
	}
	while (argv[argc]) {
		if (lua_type(L, argc + 2) == LUA_TSTRING)
			free(*(char **)(argv[argc]));
		free(argv[argc++]);
	};
	free(argv);
	if (o->type == &ffi_type_void) return 0;
	if (o->str) {
		if ( lua_checkstack(L, 1) == 0 ) return 0;
		lua_pushstring(L, *(char **)(o->ret));
		return 1;
	} else return type_push(L, o->ret, o->type);
}
/* }}} dlffi_run */

/* {{{ void dlffi_Pointer_gc(dlffi_Pointer *) */
static int dlffi_Pointer_gc(lua_State *L) {
	dlffi_Pointer *o = dlffi_check_Pointer(L, 1);
	if (!o) return 0;
	if (o->ref != 0) {
		if ( lua_checkstack(L, 2) != 0 ) {
			lua_rawgeti(L, LUA_REGISTRYINDEX, o->ref);
			lua_pushvalue(L, 1);
			lua_pcall(L, 1, 0, 0);
		}
	}
	if (o->gc == 0) return 0;
	free(o->pointer);
	return 0;
}
/* }}} dlffi_Pointer_gc */

/* {{{ void **dlffi_Pointer(void * | size_t size[, bool gc]) */
static int l_dlffi_Pointer(lua_State *L) {
	if ( lua_checkstack(L, 2) == 0 ) return 0;
	dlffi_Pointer *o = lua_newuserdata(L, sizeof(dlffi_Pointer));
	if (o == NULL) return 0;
	if (lua_gettop(L) == 1) o->pointer = NULL;
	else {
		switch (lua_type(L, 1)) {
		case LUA_TUSERDATA:
			o->pointer = dlffi_check_Pointer(L, 1);
			break;
		case LUA_TLIGHTUSERDATA:
			o->pointer = lua_touserdata(L, 1);
			break;
		case LUA_TNUMBER:
			o->pointer = malloc(lua_tointeger(L, 1));
			if (o->pointer == NULL) return 0;
			break;
		default:
			return 0;
		}
	}
	luaL_getmetatable(L, "dlffi_Pointer");
	if ((lua_type(L, 2) == LUA_TBOOLEAN) && lua_toboolean(L, 2)) {
		o->gc = 1;
	} else o->gc = 0;
	o->ref = LUA_REFNIL;
	lua_setmetatable(L, -2);
	return 1;
}
/* }}} dlffi_Pointer */

/* {{{ dlffi_Pointer_copy(void *) */
//	make a copy of the given pointer
static int l_dlffi_Pointer_copy(lua_State *L) {
	dlffi_Pointer *p = dlffi_check_Pointer(L, 1);
	if (lua_checkstack(L, 2) == 0) return 0;
	dlffi_Pointer *o = lua_newuserdata(L, sizeof(dlffi_Pointer));
	if (!o) return 0;
	o->pointer = p->pointer;
	luaL_getmetatable(L, "dlffi_Pointer");
	o->gc = 0;
	o->ref = LUA_REFNIL;
	lua_setmetatable(L, -2);
	return 1;
}
/* }}} dlffi_Pointer_copy */

/* {{{ void dlffi_gc(dlffi_Function *) */
static int dlffi_gc(lua_State *L) {
	dlffi_Function *o = lua_touserdata(L, 1);
	if (!o) return 0;
	luaL_unref(L, LUA_REGISTRYINDEX, o->ref);
	if (o->dlhdl) {
		dlclose(o->dlhdl);
		dlerror();
	}
	free(o->types);
	if (o->str && o->ret) free(*(char **)o->ret);
	if (o->ret) free(o->ret);
	return 0;
}
/* }}} dlffi_gc */

/* {{{ void dlffi_Pointer_eq(dlffi_Pointer) */
static int dlffi_Pointer_eq(lua_State *L) {
	dlffi_Pointer *o = dlffi_check_Pointer(L, 1);
	if (!o) return 0;
	int t = lua_type(L, 2);
	if ( lua_checkstack(L, 1) == 0 ) return 0;
	if (t == LUA_TLIGHTUSERDATA) {
		lua_pushboolean(L, lua_touserdata(L, 2) == o->pointer);
	} else if (t == LUA_TUSERDATA) {
		dlffi_Pointer *r = dlffi_check_Pointer(L, 2);
		lua_pushboolean(L, r->pointer == o->pointer);
	} else return 0;
	return 1;
}
/* }}} dlffi_Pointer_eq */

/* {{{ void dlffi_Pointer_sub(dlffi_Pointer) */
static int dlffi_Pointer_sub(lua_State *L) {
	dlffi_Pointer *o = dlffi_check_Pointer(L, 1);
	if (!o) return 0;
	int t = lua_type(L, 2);
	if ( lua_checkstack(L, 1) == 0 ) return 0;
	if (t == LUA_TLIGHTUSERDATA) {
		lua_pushnumber(
			L,
			(lua_Number)
			(
			(size_t)(o->pointer) -
			(size_t)lua_touserdata(L, 2)
			)
		);
	} else if (t == LUA_TUSERDATA) {
		dlffi_Pointer *r = dlffi_check_Pointer(L, 2);
		lua_pushnumber(
			L,
			(lua_Number)
			(
			(size_t)(o->pointer) -
			(size_t)(r->pointer)
			)
		);
	} else return 0;
	return 1;
}
/* }}} dlffi_Pointer_sub */

/* {{{ void dlffi_Pointer_index(dlffi_Pointer) */
static int l_dlffi_Pointer_index(lua_State *L) {
	dlffi_Pointer *o = dlffi_check_Pointer(L, 1);
	if (!o) return 0;
	if (! o->pointer) return 0;
	lua_Integer idx = luaL_checkinteger(L, 2);
	if (idx < 1) return 0;
	ffi_type *type = lua_touserdata(L, 3);
	if (!type) {
		if ( lua_checkstack(L, 2) == 0 ) return 0;
		dlffi_Pointer *new = (dlffi_Pointer *)
			lua_newuserdata(L, sizeof(dlffi_Pointer));
		if (new == NULL) return 0;
		new->pointer = ((void **)(o->pointer))[(size_t)idx - 1];
		new->gc = 0;
		new->ref = LUA_REFNIL;
		luaL_getmetatable(L, "dlffi_Pointer");
		lua_setmetatable(L, -2);
		lua_pushlightuserdata( L, new->pointer );
		return 2;
	}
	void *new = (void *)(
		((char *)(o->pointer)) +
		type->size * (idx - 1)
	);
	return type_push(L, new, type);
}
/* }}} dlffi_Pointer_index */

/* {{{ void dlffi_Pointer_set_gc(dlffi_Pointer, function) */
static int l_dlffi_Pointer_set_gc(lua_State *L) {
	dlffi_Pointer *o = dlffi_check_Pointer(L, 1);
	if (!o) return 0;
	if (lua_gettop(L) != 2) {
		o->ref = LUA_REFNIL;
		return 0;
	}
	o->ref = luaL_ref(L, LUA_REGISTRYINDEX);
	return 0;
}
/* }}} dlffi_Pointer_set_gc */

/* {{{ void dlffi_Pointer_tostring(dlffi_Pointer) */
static int l_dlffi_Pointer_tostring(lua_State *L) {
	dlffi_Pointer *o = dlffi_check_Pointer(L, 1);
	if (!o) return 0;
	if ( lua_checkstack(L, 1) == 0 ) return 0;
	if (! o->pointer) {
		lua_pushstring(L, "");
	} else {
		if (lua_type(L, 2) == LUA_TNUMBER) {
			lua_Integer len = lua_tointeger(L, 2);
			if (len < 0) return 0;
			lua_pushlstring(L, (const char *) o->pointer, len);
		} else {
			lua_pushstring(L, (const char *) o->pointer);
		}
	}
	return 1;
}
/* }}} dlffi_Pointer_tostring */

/* {{{ size_t dlffi_sizeof(char *type) */
static int l_dlffi_sizeof(lua_State *L) {
	ffi_type *p = NULL;
	switch (lua_type(L, 1)) {
	case LUA_TLIGHTUSERDATA:
		if (lua_checkstack(L, 1) == 0) return 0;
		p = lua_touserdata(L, 1);
	case LUA_TUSERDATA:
		if (p == NULL) {
			if (lua_checkstack(L, 1) == 0) return 0;
			p = (ffi_type *)((dlffi_check_Pointer(L, 1))->pointer);
		}
		lua_pushinteger(L, (lua_Integer) p->size);
		return 1;
	case LUA_TSTRING:
		break;
	default:
		return 0;
	}
	const char *t = luaL_checkstring(L, 1);
	const char *types[] = {
		"size_t",
		"void *",
		NULL
	};
	const size_t sizes[] = {
		sizeof(size_t),
		sizeof(void *)
	};
	size_t i = 0;
	while (types[i]) {
		if (strcmp(t, types[i]) == 0) {
			if ( lua_checkstack(L, 1) == 0 ) return 0;
			lua_pushinteger(L, (int)(sizes[i]));
			return 1;
		}
		i += 1;
	}
	return 0;
}
/* }}} dlffi_sizeof */

static const struct luaL_reg liblua_dlffi [] = {
	{"type_init", l_dlffi_type_init},
	{"type_offset", l_dlffi_type_offset},
	{"type_element", l_dlffi_type_element},
	{"type_free", l_dlffi_type_free},
	{"load", l_dlffi_load},
	{"sizeof", l_dlffi_sizeof},
	{"dlffi_Pointer", l_dlffi_Pointer},
	{NULL, NULL}
};

static const struct luaL_reg liblua_dlffi_m [] = {
	{"str", dlffi_Function_str},
	{NULL, NULL}
};

static const struct luaL_reg liblua_dlffi_Pointer_m [] = {
	{"index", l_dlffi_Pointer_index},
	{"tostring", l_dlffi_Pointer_tostring},
	{"set_gc", l_dlffi_Pointer_set_gc},
	{"copy", l_dlffi_Pointer_copy},
	{NULL, NULL}
};

int luaopen_liblua_dlffi(lua_State *L) {
	static char been_here;
	if ( lua_checkstack(L, 3) == 0 ) return 0;
	if (!been_here) {
	/* {{{ dlffi_Function metatable */
	luaL_newmetatable(L, "dlffi_Function");
	lua_pushstring(L, "__index");
	lua_pushvalue(L, -2);
	lua_settable(L, -3);
	lua_pushstring(L, "__gc");
	lua_pushcfunction(L, dlffi_gc);
	lua_settable(L, -3);
	lua_pushstring(L, "__call");
	lua_pushcfunction(L, dlffi_run);
	lua_settable(L, -3);
	luaL_register(L, NULL, liblua_dlffi_m);
	/* }}} dlffi_Function metatable */
	/* {{{ dlffi_Pointer metatable */
	luaL_newmetatable(L, "dlffi_Pointer");
	lua_pushstring(L, "__index");
	lua_pushvalue(L, -2);
	lua_settable(L, -3);
	lua_pushstring(L, "__eq");
	lua_pushcfunction(L, dlffi_Pointer_eq);
	lua_settable(L, -3);
	lua_pushstring(L, "__sub");
	lua_pushcfunction(L, dlffi_Pointer_sub);
	lua_settable(L, -3);
	lua_pushstring(L, "__gc");
	lua_pushcfunction(L, dlffi_Pointer_gc);
	lua_settable(L, -3);
	luaL_register(L, NULL, liblua_dlffi_Pointer_m);
	/* }}} dlffi_Pointer metatable */
	}
	luaL_register(L, "dlffi", liblua_dlffi);
	/* {{{ ffi constants */
	lua_pushlightuserdata(L, &ffi_type_uint8);
	lua_setfield(L, -2, "ffi_type_uint8");
	lua_pushlightuserdata(L, &ffi_type_sint8);
	lua_setfield(L, -2, "ffi_type_sint8");
	lua_pushlightuserdata(L, &ffi_type_uint16);
	lua_setfield(L, -2, "ffi_type_uint16");
	lua_pushlightuserdata(L, &ffi_type_sint16);
	lua_setfield(L, -2, "ffi_type_sint16");
	lua_pushlightuserdata(L, &ffi_type_uint32);
	lua_setfield(L, -2, "ffi_type_uint32");
	lua_pushlightuserdata(L, &ffi_type_sint32);
	lua_setfield(L, -2, "ffi_type_sint32");
	lua_pushlightuserdata(L, &ffi_type_uint64);
	lua_setfield(L, -2, "ffi_type_uint64");
	lua_pushlightuserdata(L, &ffi_type_sint64);
	lua_setfield(L, -2, "ffi_type_sint64");
	lua_pushlightuserdata(L, &ffi_type_uchar);
	lua_setfield(L, -2, "ffi_type_uchar");
	lua_pushlightuserdata(L, &ffi_type_schar);
	lua_setfield(L, -2, "ffi_type_schar");
	lua_pushlightuserdata(L, &ffi_type_ushort);
	lua_setfield(L, -2, "ffi_type_ushort");
	lua_pushlightuserdata(L, &ffi_type_sshort);
	lua_setfield(L, -2, "ffi_type_sshort");
	lua_pushlightuserdata(L, &ffi_type_ulong);
	lua_setfield(L, -2, "ffi_type_ulong");
	lua_pushlightuserdata(L, &ffi_type_slong);
	lua_setfield(L, -2, "ffi_type_slong");
	lua_pushlightuserdata(L, &ffi_type_uint);
	lua_setfield(L, -2, "ffi_type_uint");
	lua_pushlightuserdata(L, &ffi_type_sint);
	lua_setfield(L, -2, "ffi_type_sint");
	lua_pushlightuserdata(L, &ffi_type_float);
	lua_setfield(L, -2, "ffi_type_float");
	lua_pushlightuserdata(L, &ffi_type_double);
	lua_setfield(L, -2, "ffi_type_double");
	lua_pushlightuserdata(L, &ffi_type_void);
	lua_setfield(L, -2, "ffi_type_void");
	lua_pushlightuserdata(L, &ffi_type_pointer);
	lua_setfield(L, -2, "ffi_type_pointer");
	ffi_type *T_size_t = NULL;
	switch (sizeof(size_t)) {
	case 1:
		T_size_t = &ffi_type_uint8;
		break;
	case 2:
		T_size_t = &ffi_type_uint16;
		break;
	case 4:
		T_size_t = &ffi_type_uint32;
		break;
	case 8:
		T_size_t = &ffi_type_uint64;
		break;
	}
	if (T_size_t != NULL) {
		lua_pushlightuserdata(L, T_size_t);
		lua_setfield(L, -2, "ffi_type_size_t");
	}
	/* }}} ffi constants */
	/* {{{ NULL */
	lua_pushlightuserdata(L, NULL);
	lua_setfield(L, -2, "NULL");
	/* }}} NULL */
	return 1;
}

// vim: set foldmethod=marker:
