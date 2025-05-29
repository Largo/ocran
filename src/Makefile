CC              := gcc
EXEEXT          := .exe

CFLAGS          := -Wall -O2 -DWITH_LZMA -Ilzma
STUB_CFLAGS     := $(CFLAGS) -D_CONSOLE
STUBW_CFLAGS    := $(CFLAGS)
LDFLAGS         := -s
GUI_LDFLAGS     := -mwindows

BINDIR          := $(CURDIR)/../share/ocran
PROG_NAMES      := stub stubw edicon
BINARIES        := $(addsuffix $(EXEEXT), $(PROG_NAMES))

LZMA_SRCS       := lzma/LzmaDec.c
LZMA_OBJS       := $(LZMA_SRCS:.c=.o)

COMMON_SRCS     := filesystem_utils.c inst_dir.c script_info.c unpack.c
COMMON_OBJS     := $(COMMON_SRCS:.c=.o) $(LZMA_OBJS) stub.res

VARIANT_SRCS    := stub.c error.c
CONSOLE_OBJS    := $(VARIANT_SRCS:.c=_console.o)
WINDOW_OBJS     := $(VARIANT_SRCS:.c=_window.o)

.PHONY: all clean install
all: $(BINARIES)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%_console.o: %.c
	$(CC) $(STUB_CFLAGS) -c $< -o $@ 

%_window.o: %.c
	$(CC) $(STUBW_CFLAGS) -c $< -o $@ 

stub.res: stub.rc
	windres -i stub.rc -O coff -o stub.res

stub$(EXEEXT): $(COMMON_OBJS) $(CONSOLE_OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

stubw$(EXEEXT): $(COMMON_OBJS) $(WINDOW_OBJS)
	$(CC) $(LDFLAGS) $(GUI_LDFLAGS) $^ -o $@

edicon$(EXEEXT): edicon.o
	$(CC) $(LDFLAGS) $^ -o $@

clean:
	rm -f $(BINARIES) $(COMMON_OBJS) $(CONSOLE_OBJS) $(WINDOW_OBJS) \
	      edicon.o

install: $(BINARIES)
	mkdir -p $(BINDIR)
	cp -f $(BINARIES) $(BINDIR)/
