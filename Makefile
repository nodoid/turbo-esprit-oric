# Turbo Esprit for the Oric Atmos.  Needs cc65 (ca65/ld65) and python3.
AS      = ca65
LD      = ld65
BUILD   = build
TAP     = $(BUILD)/turbo.tap
ORIC    = $(HOME)/Downloads/Oric v1.8.3/Oric.app

SRCS    = $(wildcard src/*.s)
DSRCS   = $(wildcard data/*.s)
OBJS    = $(patsubst src/%.s,$(BUILD)/%.o,$(SRCS)) $(patsubst data/%.s,$(BUILD)/data_%.o,$(DSRCS))

all: $(TAP)

$(BUILD)/%.o: src/%.s $(wildcard src/*.inc) | $(BUILD)
	$(AS) -g -I src -I data --bin-include-dir data -o $@ $<

$(BUILD)/data_%.o: data/%.s | $(BUILD)
	$(AS) -g -I src -I data --bin-include-dir data -o $@ $<

$(BUILD)/turbo.bin: $(OBJS) src/turbo.cfg
	$(LD) -C src/turbo.cfg -m $(BUILD)/turbo.map -Ln $(BUILD)/turbo.lbl -o $@ $(OBJS)

$(TAP): $(BUILD)/turbo.bin data/loadscr.bin tools/mktap.py
	python3 tools/mktap.py $@ 0x600 SCREEN:0xA000:data/loadscr.bin ESPRIT:0x600:$(BUILD)/turbo.bin

# regenerate data/ from the original Spectrum tape (orig/TurboEsprit.tzx)
extract:
	python3 tools/mkloadscr.py orig/TurboEsprit.tzx data/loadscr.bin
	python3 tools/gen_objects.py orig/TurboEsprit.tzx data/objects_data.s
	python3 tools/gen_snd.py
	python3 tools/gen_render.py

$(BUILD):
	mkdir -p $(BUILD)

run: $(TAP)
	open -a "$(ORIC)" $(TAP)

clean:
	rm -rf $(BUILD)

.PHONY: all run clean extract
