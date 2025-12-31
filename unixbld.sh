#!/bin/bash -e

uasm -bin DRVSRC/HDA16S.ASM
mv -v HD{A,W}16S.BIN
uasm -bin -D?FLASHTEK=1 DRVSRC/HDA16S.asm
./hmiappnd oldfile=$HOME/Games/rayman-forever/Rayman/HMIDRV.OLD newfile=$HOME/Games/rayman-forever/Rayman/HMIDRV.386 drvf:E040=HDA16S.BIN drvr:E040=HDW16S.BIN

uasm -bin DRVSRC/HDA16SD.ASM
mv -v HD{A,W}16SD.BIN
uasm -bin -D?FLASHTEK=1 DRVSRC/HDA16SD.ASM
./hmiappnd oldfile=$HOME/Games/rayman-forever/Rayman/HMIDET.OLD newfile=$HOME/Games/rayman-forever/Rayman/HMIDET.386 drvf:E040=HDA16SD.BIN drvr:E040=HDW16SD.BIN

uasm -bin TOOLSRC/HMIREDIR.ASM
mv -v HMIREDIR.{BIN,COM}

uasm -IDRVSRC -bin RAYTOOLS/SOUNDBIN.ASM
mv -v SOUNDBIN.{BIN,COM}
