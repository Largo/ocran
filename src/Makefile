SRCS = lzma/LzmaDec.c
OBJS = $(SRCS:.c=.o) stub.res
CONSOLE_OBJS = error_console.o filesystem_utils_console.o inst_dir_console.o script_info_console.o unpack_console.o
WINDOW_OBJS = error_window.o filesystem_utils_window.o inst_dir_window.o script_info_window.o unpack_window.o
CC = gcc
BINDIR = $(CURDIR)/../share/ocran

CFLAGS = -Wall -O2 -DWITH_LZMA -Ilzma -s
STUB_CFLAGS = -D_CONSOLE $(CFLAGS)
STUBW_CFLAGS = -mwindows $(CFLAGS)
# -D_MBCS

all: stub.exe stubw.exe edicon.exe

stub.res: stub.rc
	windres -i stub.rc -O coff -o stub.res

stub.exe: $(OBJS) stub.o $(CONSOLE_OBJS)
	$(CC) $(STUB_CFLAGS) $(OBJS) stub.o $(CONSOLE_OBJS) -o $@

stubw.exe: $(OBJS) stubw.o $(WINDOW_OBJS)
	$(CC) $(STUBW_CFLAGS) $(OBJS) stubw.o $(WINDOW_OBJS) -o $@

edicon.exe: edicon.o
	$(CC) $(CFLAGS) edicon.o -o edicon

error_console.o: error.c error.h
	$(CC) $(STUB_CFLAGS) -o $@ -c $<

error_window.o: error.c error.h
	$(CC) $(STUBW_CFLAGS) -o $@ -c $<

stub.o: stub.c stub.h
	$(CC) $(STUB_CFLAGS) -o $@ -c $<

stubw.o: stub.c stub.h
	$(CC) $(STUBW_CFLAGS) -o $@ -c $<

unpack_console.o: unpack.c unpack.h
	$(CC) $(STUB_CFLAGS) -o $@ -c $<

unpack_window.o: unpack.c unpack.h
	$(CC) $(STUBW_CFLAGS) -o $@ -c $<

filesystem_utils_console.o: filesystem_utils.c filesystem_utils.h
	$(CC) $(STUB_CFLAGS) -o $@ -c $<

filesystem_utils_window.o: filesystem_utils.c filesystem_utils.h
	$(CC) $(STUBW_CFLAGS) -o $@ -c $<

inst_dir_console.o: inst_dir.c inst_dir.h
	$(CC) $(STUB_CFLAGS) -o $@ -c $<

inst_dir_window.o: inst_dir.c inst_dir.h
	$(CC) $(STUBW_CFLAGS) -o $@ -c $<

script_info_console.o: script_info.c script_info.h
	$(CC) $(STUB_CFLAGS) -o $@ -c $<

script_info_window.o: script_info.c script_info.h
	$(CC) $(STUBW_CFLAGS) -o $@ -c $<

clean:
	rm -f $(OBJS) stub.exe stubw.exe edicon.exe edicon.o stubw.o stub.o \
	$(CONSOLE_OBJS) $(WINDOW_OBJS)

install: stub.exe stubw.exe edicon.exe
	cp -f stub.exe $(BINDIR)/stub.exe
	cp -f stubw.exe $(BINDIR)/stubw.exe
	cp -f edicon.exe $(BINDIR)/edicon.exe
