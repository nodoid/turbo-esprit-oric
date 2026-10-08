# Turbo Esprit for the Oric Atmos.  Needs cc65 (ca65/ld65) and python3.
AS      = ca65
LD      = ld65
BUILD   = build
TAP     = $(BUILD)/turbo.tap
DSK     = $(BUILD)/turbo.dsk
# tap2dsk (Euphoric tools, carries Sedoric 3) - needed for the disk image
TAP2DSK ?= tap2dsk
ORIC    = $(HOME)/Downloads/Oric v1.8.3/Oric.app

SRCS    = $(wildcard src/*.s)
# generated data assembled as modules of their own (others are .included)
DSRCS   = data/view_data.s data/gfx_data.s
OBJS    = $(patsubst src/%.s,$(BUILD)/%.o,$(SRCS)) $(patsubst data/%.s,$(BUILD)/data_%.o,$(DSRCS))

all: $(DSK) $(TAP)

$(DSK): $(BUILD)/turbo.bin data/loadscr.bin tools/mkdsk.py
	TAP2DSK=$(TAP2DSK) python3 tools/mkdsk.py $@ data/loadscr.bin $(BUILD)/turbo.bin $(BUILD)/turbo.bin.ovl

$(BUILD)/%.o: src/%.s $(wildcard src/*.inc) | $(BUILD)
	$(AS) -g -I src -I data --bin-include-dir data -o $@ $<

$(BUILD)/data_%.o: data/%.s | $(BUILD)
	$(AS) -g -I src -I data --bin-include-dir data -o $@ $<

$(BUILD)/turbo.bin: $(OBJS) src/turbo.cfg
	$(LD) -C src/turbo.cfg -m $(BUILD)/turbo.map -Ln $(BUILD)/turbo.lbl -o $@ $(OBJS)

$(TAP): $(BUILD)/turbo.bin data/loadscr.bin tools/mktap.py
	python3 tools/mktap.py $@ data/loadscr.bin $(BUILD)/turbo.bin.ovl $(BUILD)/turbo.bin

# regenerate data/ from the original Spectrum tape (orig/TurboEsprit.tzx)
extract:
	python3 tools/mkloadscr.py orig/TurboEsprit.tzx data/loadscr.bin
	cd tools && python3 gen_zxram.py ../orig/TurboEsprit.tzx ../data/zxram.bin
	python3 tools/gen_objects.py orig/TurboEsprit.tzx data/objects_data.s
	python3 tools/gen_snd.py
	python3 tools/gen_render.py
	python3 tools/gen_world.py
	python3 tools/gen_gfx.py

$(BUILD):
	mkdir -p $(BUILD)

# runs the disk in Oricutron (Atmos + Microdisc); OCDIR = Oricutron directory
run: $(DSK)
	tools/ocdisk.sh $(DSK) 0

clean:
	rm -rf $(BUILD)

.PHONY: all run clean extract
