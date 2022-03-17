# HMIDRV_HDAudio
This is a driver for [Intel High Definition Audio](https://en.wikipedia.org/wiki/Intel_High_Definition_Audio) controllers, for use with Human Machine Interface's (HMI's) Sound Operating System **version 3**, perhaps better known as `HMIDRV.386`.
The project was inspired by [Japheth's `HDAUtils`](https://github.com/Baron-von-Riedesel/HDAutils), and the idea is to give old DOS programs / games (such as Rayman) the ability to play sound through modern hardware.
So far, it has been tested with the aforementioned Rayman, on MS-DOS 6.2 running on a PC from 2014 with [this motherboard](https://us.msi.com/Motherboard/Z97-GAMING-3) (to clarify, I'm booting DOS *natively* on the system, not with QEMU or the like).

The driver can interface with `HDATSR.EXE` from the [Windows 3.1 HDA sound driver](https://retrosystemsrevival.blogspot.com/2019/06/windows-31959898se-hda-driver.html).
If this TSR is not present, the driver can attempt to allocate its own buffers using XMS (or directly from the DOS extender if paging is off).
That said, the TSR is the most sure-fire way to ensure the driver has memory available for all the necessary buffers.

Experimental support is also included for mixing CD Audio into the stream, by hooking MSCDEX, since modern computers tend not to have analogue music players (with direct connections to the sound card) built into optical drives anymore.

At this point, the performance of the detector and driver seems satisfactory on *Rayman Designer*, which can detect arbitrary sound cards on startup using `HMIDET.386`.
When both `HMIDRV.386` and `HMIDET.386` are patched, a fresh install of Rayman Designer can detect HD Audio hardware, and after closing and reopening, play sound and CD Audio through it. There is still room for improvement (see below) but it's already working quite well.
Further patching is required for *Rayman Junior*, which needs changes to `SOUND.BIN` (using the `SOUNDBIN.ASM` utility in the `RAYTOOLS` folder), and has an installer that only runs from CD, necessitating the use of the `HMIREDIR` tool (see `RAYTOOLS/EXAMPLE.BAT` for how I did it).
Other games will likely have quirks of their own!

## Limitations
* Only supports version 3 of the Sound Operating System, used in Rayman. Version 4 is not supported.
* Only tested with `RATIONAL`-type (i.e. DOS/4GW-like) DOS extenders, not `FLASHTECK` [*[sic]*](https://github.com/Wohlstand/SOSPLAY/blob/master/sos3/include/sos.h#L574) (i.e. FlashTek X-32VM and similar).
  * CD Audio won't work under FlashTek unless there is a DPMI host running behind it.
* Currently only supports 16-bit stereo playback
* CD Audio requires your drive to support raw reading (and support is currently incomplete - see below)
* Cannot run under Windows 3.1/9x with the aforementioned HDA sound driver running - they will conflict
* Detector doesn't seem to be useful in combination with installer programs like Rayman's, which contain a fixed list of known sound cards (so they will basically ignore this new unknown one even if it's detected)
  * Most versions of Rayman have an external file that can be modified to include references to this driver. If other games do this, then each game will need some work to get it working with this driver (i.e. it's unfortunately not plug and play).

## `TODO` list
* Figure out cause of skipping in looping sounds, and eliminate it
* Implement support for volume control of CD Audio even when the drive doesn't have built-in audio capability
* Implement support for four-channel CDs (playing two channels, which can be selected by running applications)
* [MAYBE] look into using EMS instead of Conventional Memory for CD Audio buffers
  * Right now, any game that hogs Conventional Memory can't play CD Audio through this driver at all.
  * Rayman Junior is an interesting case, in that I've found when `EMM386.EXE` is installed, I can play CD Audio with an 8-sector buffer, but this is simply impossible without an EMM.
* [MAYBE] find something using FlashTek and use it to test the driver
* [MAYBE] implement support for pre-emphasis in CD Audio
* [MAYBE] make 8-bit and mono versions

## Build / Usage instructions
Example build scripts are included for DOS (`DOSBUILD.BAT`) and Linux (`unixbld.sh`), but it could also be built on Windows without much additional effort (but at any rate, the driver itself is only useful on DOS!).

Essentially, the steps are:
* Assemble the driver, `drvsrc/hda16s.asm` (with the `-D?FLASHTEK` option if targeting that DOS extender), as a binary (`.BIN`) file, using [JWASM](https://www.japheth.de/JWasm.html) or similar.
* Likewise assemble the detector, `drvsrc/HDA16SD.ASM`.
* Use `HMIAPPND` to patch your game's `HMIDRV.386` and `HMIDET.386` files. A DOS EXE of this patcher is included in the source repo, or you can build it yourself from `HMIAPPND.C` (example build scripts are `BOOTSTRP.BAT` for DOS, using Open Watcom, and `BOOTSTRP.SH` for Linux, using GCC).
* To assist the detector in finding your hardware, it's advisable to set the environment variables `HDA_BUS`, `HDA_DEVICE`, `HDA_FUNCTION`, `HDA_CODEC` and `HDA_WIDGET`. [Japheth's `HDAUtils`](https://github.com/Baron-von-Riedesel/HDAutils) can help you enumerate your hardware and find the appropriate values for these. They should all be specified in hex **without** leading `0x` or anything like that.
* If you want CD Audio to play through the driver, make sure `SMARTDRV` isn't running on your system.
  * The driver will not play CD Audio if it detects `SMARTDRV`. If it did, it would lead to buffer underflow and hence unpleasant crackling.
* If your game has an installer that detects the sound card which must be run from a CD (i.e. you can't directly modify its copy of `HMIDET.386`), you'll need to run `HMIREDIR` with the path to the directory containing your patched `HMIDET.386`. `HMIREDIR` should be assembled as a `.BIN` file and then renamed to `HMIREDIR.COM` to run it as a TSR.
  * There may be other complications with game installers, like custom file formats containing a list of sound cards (instead of just reading them from SOS itself). The `RAYTOOLS` folder contains source for another program to deal with one such binary format, and an `EXAMPLE.BAT` file showing how to deal with it for one particular *Rayman* game. Other Rayman iterations have text formats, and still others have built-in lists in the installer `EXE` itself.
