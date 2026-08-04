BUILD_DIR := build
SRC := src/thumosd.m
BIN := $(BUILD_DIR)/thumosd
UI_SRC := src/thumos-menu.m
APP := $(BUILD_DIR)/ThumOS.app
APP_BIN := $(APP)/Contents/MacOS/ThumOS
APP_DAEMON := $(APP)/Contents/MacOS/thumosd
APP_INFO := $(APP)/Contents/Info.plist
APP_ICON := $(APP)/Contents/Resources/ThumOS.icns
APP_MODEL_DIR := $(APP)/Contents/Resources/Model
TRAINER_SRC := scripts/train_classifier.py
ICON_SRC := scripts/render-app-icon.m
ICON_RENDERER := $(BUILD_DIR)/render-app-icon
ICONSET := $(BUILD_DIR)/ThumOS.iconset
ICON := $(BUILD_DIR)/ThumOS.icns

export CLANG_MODULE_CACHE_PATH := $(BUILD_DIR)/module-cache

.PHONY: all app init run discover-hid list-hid clear-events install-launch-agent open-ui

all: $(BIN) app

$(BIN): $(SRC)
	mkdir -p $(BUILD_DIR) $(CLANG_MODULE_CACHE_PATH)
	clang -fobjc-arc -Wall -Wextra -Werror -ObjC \
		-framework Foundation \
		-framework ApplicationServices \
		-framework AppKit \
		-framework IOKit \
		-lsqlite3 \
		$(SRC) -o $(BIN)

$(ICON_RENDERER): $(ICON_SRC)
	mkdir -p $(BUILD_DIR) $(CLANG_MODULE_CACHE_PATH)
	clang -fobjc-arc -Wall -Wextra -Werror -ObjC \
		-framework Foundation \
		-framework AppKit \
		$(ICON_SRC) -o "$(ICON_RENDERER)"

$(ICON): $(ICON_RENDERER)
	"$(ICON_RENDERER)" "$(ICONSET)" "$(ICON)"

app: $(BIN) $(UI_SRC) packaging/ThumOS-Info.plist $(ICON) $(TRAINER_SRC)
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(APP_MODEL_DIR)" $(CLANG_MODULE_CACHE_PATH)
	clang -fobjc-arc -Wall -Wextra -Werror -ObjC \
		-framework Foundation \
		-framework AppKit \
		-framework CoreBluetooth \
		-framework IOKit \
		-framework UniformTypeIdentifiers \
		-lsqlite3 \
		$(UI_SRC) -o "$(APP_BIN)"
	cp "$(BIN)" "$(APP_DAEMON)"
	cp packaging/ThumOS-Info.plist "$(APP_INFO)"
	cp "$(ICON)" "$(APP_ICON)"
	cp "$(TRAINER_SRC)" "$(APP_MODEL_DIR)/train_classifier.py"
	codesign --force --sign - --identifier io.thumos.daemon --requirements '=designated => identifier "io.thumos.daemon"' "$(APP_DAEMON)"
	codesign --force --sign - --requirements '=designated => identifier "io.thumos.menu"' "$(APP)"

init: $(BIN)
	$(BIN) --init

run: $(BIN)
	$(BIN) --hid-record --hid-product Creator

discover-hid: $(BIN)
	$(BIN) --discover-hid --hid-product Creator

list-hid: $(BIN)
	$(BIN) --list-hid-devices

clear-events:
	scripts/clear-events.sh

install-launch-agent: $(BIN)
	scripts/install-launch-agent.sh "$(abspath $(BIN))"

open-ui: app
	open "$(APP)"
