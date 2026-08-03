BUILD_DIR := build
SRC := src/thumosd.m
BIN := $(BUILD_DIR)/thumosd

export CLANG_MODULE_CACHE_PATH := $(BUILD_DIR)/module-cache

.PHONY: all init run install-launch-agent

all: $(BIN)

$(BIN): $(SRC)
	mkdir -p $(BUILD_DIR) $(CLANG_MODULE_CACHE_PATH)
	clang -fobjc-arc -Wall -Wextra -Werror -ObjC \
		-framework Foundation \
		-framework ApplicationServices \
		-framework AppKit \
		-framework IOKit \
		-lsqlite3 \
		$(SRC) -o $(BIN)

init: $(BIN)
	$(BIN) --init

run: $(BIN)
	$(BIN) --hid-record --hid-product Creator

discover-hid: $(BIN)
	$(BIN) --discover-hid --hid-product Creator

list-hid: $(BIN)
	$(BIN) --list-hid-devices

install-launch-agent: $(BIN)
	scripts/install-launch-agent.sh "$(abspath $(BIN))"
