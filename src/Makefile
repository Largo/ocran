# Detect host OS
#
# Experimental: the POSIX stub also builds with Cosmopolitan Libc
# (https://github.com/jart/cosmopolitan) into an Actually Portable
# Executable:  make CC=cosmocc
# See ../docs/cosmocc-port-plan.md for status and caveats.
UNAME           := $(shell uname -s 2>/dev/null || echo Windows)
IS_POSIX        := $(filter $(UNAME),Linux Darwin)

CC              := gcc
CFLAGS          := -Wall -O2 -DWITH_LZMA -Ilzma
LDFLAGS         := -s

ifneq ($(IS_POSIX),)
  EXEEXT          :=
  LDLIBS          :=
  GUI_LDFLAGS     :=
  STUB_CFLAGS     := $(CFLAGS) -D_CONSOLE
  SYSTEM_UTILS_SRC := system_utils_posix.c
  PROG_NAMES      := stub
  RESOURCE_OBJ    :=
else
  EXEEXT          := .exe
  LDLIBS          := -lbcrypt
  GUI_LDFLAGS     := -mwindows
  STUB_CFLAGS     := $(CFLAGS) -D_CONSOLE
  STUBW_CFLAGS    := $(CFLAGS)
  SYSTEM_UTILS_SRC := system_utils.c
  PROG_NAMES      := stub stubw
  RESOURCE_OBJ    := stub.res
endif

BINDIR          := $(CURDIR)/../share/ocran
BINARIES        := $(addsuffix $(EXEEXT), $(PROG_NAMES))

LZMA_SRCS       := lzma/LzmaDec.c
LZMA_OBJS       := $(LZMA_SRCS:.c=.o)

COMMON_SRCS     := $(SYSTEM_UTILS_SRC) inst_dir.c script_info.c unpack.c
COMMON_OBJS     := $(COMMON_SRCS:.c=.o) $(LZMA_OBJS) $(RESOURCE_OBJ)

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

ifeq ($(IS_POSIX),)
stub.res: stub.rc
	windres -i stub.rc -O coff -o stub.res
endif

stub$(EXEEXT): $(COMMON_OBJS) $(CONSOLE_OBJS)
	$(CC) $(LDFLAGS) $^ $(LDLIBS) -o $@

ifeq ($(IS_POSIX),)
stubw$(EXEEXT): $(COMMON_OBJS) $(WINDOW_OBJS)
	$(CC) $(LDFLAGS) $(GUI_LDFLAGS) $^ $(LDLIBS) -o $@

endif

clean:
	rm -f $(BINARIES) $(COMMON_OBJS) $(CONSOLE_OBJS) $(WINDOW_OBJS) \
	      $(RESOURCE_OBJ)
	# cosmocc (CC=cosmocc) byproducts
	rm -f $(addsuffix .com.dbg, $(PROG_NAMES)) \
	      $(addsuffix .aarch64.elf, $(PROG_NAMES))
	rm -rf .aarch64 lzma/.aarch64

install: $(BINARIES)
	mkdir -p $(BINDIR)
	cp -f $(BINARIES) $(BINDIR)/
