CC ?= cc
CFLAGS ?= -O2 -g
override CFLAGS += -std=gnu11 -Wall -Wextra -Wshadow -Wconversion -Wno-sign-conversion -pthread $(shell pkg-config --cflags libdrm gbm egl glesv2 liblz4)
LDLIBS += -pthread -lm $(shell pkg-config --libs libdrm gbm egl glesv2 liblz4)
OBJECTS = main.o util.o text.o splash.o render.o output.o net.o input.o

tandem-display: $(OBJECTS)
	$(CC) $(LDFLAGS) -o $@ $(OBJECTS) $(LDLIBS)

$(OBJECTS): tandem.h

clean:
	rm -f tandem-display $(OBJECTS)

.PHONY: clean
