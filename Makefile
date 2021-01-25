# location
LUA_VERSION=5.4
PREFIX=/usr/local
DEST_LIBS=$(PREFIX)/lib/lua/$(LUA_VERSION)
INCLUDES=/usr/include/lua$(LUA_VERSION)
LUA_CFLAGS=-O2 -fPIC -I$(INCLUDES) -g -Dlua_objlen=lua_rawlen
LUA_LDFLAGS=-O -shared -fPIC

#####

all: compile
CA=-Wall -Wextra -Wno-return-local-addr
compile: dlffi

dlffi: liblua_dlffi.c
	$(CC) $(CFLAGS) $(CA) $(LUA_CFLAGS) -c liblua_dlffi.c -o liblua_dlffi.o
	$(CC) $(CFLAGS) $(CA) $(LUA_LDFLAGS) -o liblua_dlffi.so liblua_dlffi.o -ldl `pkg-config --cflags --libs lua$(LUA_VERSION) libffi`

clean:
	rm liblua_dlffi.o

distclean:
	rm liblua_dlffi.so

install:
	mkdir -p $(DEST_LIBS)
	cp -f liblua_dlffi.so $(DEST_LIBS)
	cp -f dlffi.lua $(DEST_LIBS)

