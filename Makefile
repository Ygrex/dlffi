# location
LUA_VERSION=5.1
PREFIX=/usr/local
DEST_LIBS=$(PREFIX)/lib/lua/$(LUA_VERSION)
INCLUDES=/usr/include/lua$(LUA_VERSION)
LUA_CFLAGS=-O2 -fPIC -I$(INCLUDES)
# uncomment the following line to declare lua_objlen in LUA 5.2
#LUA_CFLAGS=-O2 -fPIC -Dlua_objlen=lua_rawlen
LUA_LDFLAGS=-O -shared -fPIC

#####

all: compile
CA=-Wall -Wextra
compile: dlffi

dlffi: liblua_dlffi.c
	$(CC) $(CFLAGS) $(CA) $(LUA_CFLAGS) -c liblua_dlffi.c -o liblua_dlffi.o
	$(CC) $(CFLAGS) $(CA) $(LUA_LDFLAGS) -ldl -lffi -o liblua_dlffi.so liblua_dlffi.o

clean:
	rm liblua_dlffi.o

distclean:
	rm liblua_dlffi.so

install:
	mkdir -p $(DEST_LIBS)
	cp -f liblua_dlffi.so $(DEST_LIBS)
	cp -f dlffi.lua $(DEST_LIBS)

