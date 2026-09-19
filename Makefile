# The Hitch-Hiker's Guide to the Galaxy — 1981 TV-series tribute (Free Pascal)
#
# macOS:   make
# Linux:   sudo apt install fpc libgtk2.0-dev   &&  make linux
# Windows: from a native FPC install:            make windows

FPC      ?= fpc
SRC      := src
BUILD    := build
APP      := $(BUILD)/HitchHikersGuide.app
UNITS    := -Fu$(SRC) -FU$(BUILD) -FE$(BUILD)
FLAGS    := -Mobjfpc -Scgi -O2 -Xs

.PHONY: all app run linux windows test snap clean

all: app

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/HitchHikersGuide: $(BUILD) $(SRC)/*.pas
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/HitchHikersGuide $(SRC)/guide.pas

$(BUILD)/guidetest: $(BUILD) $(SRC)/uguidemodel.pas $(SRC)/uguideaudio.pas $(SRC)/guidetest.pas
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/guidetest $(SRC)/guidetest.pas

$(BUILD)/guidesnap: $(BUILD) $(SRC)/*.pas
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/guidesnap $(SRC)/guidesnap.pas

app: $(BUILD)/HitchHikersGuide
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BUILD)/HitchHikersGuide $(APP)/Contents/MacOS/HitchHikersGuide
	cp bundle/Info.plist $(APP)/Contents/Info.plist

run: app
	open $(APP)

linux: $(BUILD)
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/hitchhikersguide $(SRC)/guide.pas

windows: $(BUILD)
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/HitchHikersGuide.exe $(SRC)/guide.pas

test: $(BUILD)/guidetest
	$(BUILD)/guidetest

snap: $(BUILD)/guidesnap
	$(BUILD)/guidesnap $(BUILD)

clean:
	rm -rf $(BUILD)
