#!/bin/bash -e

uasm -bin DRVSRC/hda16s.asm
mv -v hd{a,w}16s.BIN
uasm -bin -D?FLASHTEK=1 DRVSRC/hda16s.asm
./hmiappnd oldfile=$HOME/Games/rayman-forever/Rayman/HMIDRV.OLD newfile=$HOME/Games/rayman-forever/Rayman/HMIDRV.386 drvf:E040=hda16s.BIN drvr:E040=hdw16s.BIN

uasm -bin DRVSRC/HDA16SD.ASM
mv -v HD{A,W}16SD.BIN
uasm -bin -D?FLASHTEK=1 DRVSRC/HDA16SD.ASM
./hmiappnd oldfile=$HOME/Games/rayman-forever/Rayman/HMIDET.OLD newfile=$HOME/Games/rayman-forever/Rayman/HMIDET.386 drvf:E040=HDA16SD.BIN drvr:E040=HDW16SD.BIN

uasm -bin TOOLSRC/HMIREDIR.ASM
mv -v HMIREDIR.{BIN,COM}

uasm -IDRVSRC -bin RAYTOOLS/SOUNDBIN.ASM
mv -v SOUNDBIN.{BIN,COM}
