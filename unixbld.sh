#!/bin/bash -e
uasm -bin drvsrc/hda16s.asm
mv hd{a,w}16s.BIN

uasm -bin -D?FLASHTEK=1 drvsrc/hda16s.asm

./hmiappnd oldfile=$HOME/Games/rayman-forever/Rayman/HMIDRV.OLD newfile=$HOME/Games/rayman-forever/Rayman/HMIDRV.386 drvf:E040=hda16s.BIN drvr:E040=hdw16s.BIN
