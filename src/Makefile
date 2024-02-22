SRCS = lzma/LzmaDec.c unpack.c
OBJS = $(SRCS:.c=.o) stubicon.o error.o
CC = gcc
BINDIR = $(CURDIR)/../share/ocran

CFLAGS = -Wall -O2 -DWITH_LZMA -Ilzma -s
STUB_CFLAGS = -D_CONSOLE $(CFLAGS)
STUBW_CFLAGS = -mwindows $(CFLAGS)
# -D_MBCS

all: stub.exe stubw.exe edicon.exe

stubicon.o: stub.rc
	windres -i $< -o $@

stub.exe: $(OBJS) stub.o
	$(CC) $(STUB_CFLAGS) $(OBJS) stub.o -o $@

stubw.exe: $(OBJS) stubw.o
	$(CC) $(STUBW_CFLAGS) $(OBJS) stubw.o -o $@

edicon.exe: edicon.o
	$(CC) $(CFLAGS) edicon.o -o edicon

error.o: error.c error.h
	$(CC) $(CFLAGS) -o $@ -c $<

stub.o: stub.c stub.h
	$(CC) $(STUB_CFLAGS) -o $@ -c $<

stubw.o: stub.c stub.h
	$(CC) $(STUBW_CFLAGS) -o $@ -c $<

unpack.o: unpack.c unpack.h
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	rm -f $(OBJS) stub.exe stubw.exe edicon.exe edicon.o stubw.o stub.o error.o

install: stub.exe stubw.exe edicon.exe
	cp -f stub.exe $(BINDIR)/stub.exe
	cp -f stubw.exe $(BINDIR)/stubw.exe
	cp -f edicon.exe $(BINDIR)/edicon.exe
