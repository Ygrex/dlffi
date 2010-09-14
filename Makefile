all: compile
CA=-Wall -Wextra
LUA_CFLAGS=-I/usr/include/lua5.1 -O2 -fPIC
LUA_LDFLAGS=-O -shared -fPIC

compile: dlffi

dlffi: liblua_dlffi.c
	$(CC) $(CFLAGS) $(CA) $(LUA_CFLAGS) -c liblua_dlffi.c -o liblua_dlffi.o
	$(CC) $(CFLAGS) $(CA) $(LUA_LDFLAGS) -ldl -lffi -o liblua_dlffi.so liblua_dlffi.o

clean:
	rm liblua_dlffi.o

distclean:
	rm liblua_dlffi.so

install:
	mkdir -p /usr/local/lib/lua/5.1/
	cp -f liblua_dlffi.so /usr/local/lib/lua/5.1/

