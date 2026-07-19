# Makefile pour compiler bw_camera.c

CC = gcc
CFLAGS = -O2 -Wall
TARGET = bw_camera

all: $(TARGET)

$(TARGET): bw_camera.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: all clean
