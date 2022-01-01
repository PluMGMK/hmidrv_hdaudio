@echo off

jwasmd -bin drvsrc\hda16s.asm
if errorlevel 1 goto detector
rem Convention is to change last letter to 'w' for "RATIONAL" version
move hda16s.bin hdw16s.bin

jwasmd -bin -D?FLASHTEK=1 drvsrc\hda16s.asm
if errorlevel 1 goto detector

hmiappnd.exe oldfile=C:\RAYMAN\HMIDRV.OLD newfile=C:\RAYMAN\HMIDRV.386 drvf:E040=hda16s.bin drvr:E040=hdw16s.bin
hmiappnd.exe oldfile=C:\RAYKIT\HMIDRV.OLD newfile=C:\RAYKIT\HMIDRV.386 drvf:E040=hda16s.bin drvr:E040=hdw16s.bin
hmiappnd.exe oldfile=C:\EDUGB1\HMIDRV.OLD newfile=C:\EDUGB1\HMIDRV.386 drvf:E040=hda16s.bin drvr:E040=hdw16s.bin

:detector
jwasmd -bin drvsrc\hda16sd.asm
if errorlevel 1 goto redirector
rem Convention is to change last letter to 'w' for "RATIONAL" version
move hda16sd.bin hdw16sd.bin

jwasmd -bin -D?FLASHTEK=1 drvsrc\hda16sd.asm
if errorlevel 1 goto redirector

hmiappnd.exe oldfile=C:\RAYMAN\HMIDET.OLD newfile=C:\RAYMAN\HMIDET.386 drvf:E040=hda16sd.bin drvr:E040=hdw16sd.bin
hmiappnd.exe oldfile=C:\RAYKIT\HMIDET.OLD newfile=C:\RAYKIT\HMIDET.386 drvf:E040=hda16sd.bin drvr:E040=hdw16sd.bin
hmiappnd.exe oldfile=C:\EDUGB1\HMIDET.OLD newfile=C:\EDUGB1\HMIDET.386 drvf:E040=hda16sd.bin drvr:E040=hdw16sd.bin

:redirector
jwasmd -bin hmiredir.asm
if errorlevel 1 goto end
move hmiredir.bin hmiredir.com

:end
