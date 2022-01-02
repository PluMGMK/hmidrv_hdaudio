' HMIAPPND.BAS
' Append new driver to the end of a HMI driver blob

' Basic parameters - input gives *16-bit* integers
' Attempting to use input for LONGs would sneakily fill the upper half with 1s!
DIM wDeviceID AS INTEGER
DIM wExtenderType AS INTEGER
INPUT "Device ID"; wDeviceID
INPUT "DOS Extender Type (&H8000=Rational, &H4000=FlashTek)"; wExtenderType

' Give a list of files to help out...
SHELL "dir"
INPUT "File to append"; szName$
IF LEN(szName$) > 32 THEN
	PRINT "Filename too long!"
	END
END IF

INPUT "Input HMIDRV.386 file"; inputfile$
INPUT "Output HMIDRV.386 file"; outputfile$

OPEN inputfile$ FOR BINARY AS #1
OPEN szName$ FOR BINARY AS #2
PRINT "Input files opened"

' Make this file freshly
OPEN outputfile$ FOR OUTPUT AS #3
PRINT #3, , ""
CLOSE #3
PRINT "Output file truncated"
OPEN outputfile$ FOR BINARY AS #3
PRINT "Output file reopened"

' Copy over the "szName" field of the file header
namebuf$ = SPACE$(32)
GET #1, , namebuf$
PUT #3, , namebuf$

' Number of drivers in the file
DIM wDrivers AS LONG
GET #1, , wDrivers
' We're appending one!
wDrivers = wDrivers + 1
PUT #3, , wDrivers
PRINT "szName and wDrivers written..."

' Buffered read/write of the old file into the new one
DIM oldfilesize AS LONG
DIM buflen AS LONG
oldfilesize = LOF(1)
buflen = 4096
buf$ = SPACE$(buflen)
WHILE LOC(1) <= (oldfilesize - buflen)
	GET #1, , buf$
	PUT #3, , buf$
WEND
rembytes = oldfilesize - LOC(1)
IF rembytes > 0 THEN
	rembuf$ = SPACE$(rembytes)
	GET #1, , rembuf$
	PUT #3, , rembuf$
END IF
PRINT "Old HMIDRV file copied to new one"

' Construct the new driver header
DIM hdrstart AS LONG
DIM lNextDriver AS LONG
DIM wSize AS LONG
' Where is the current header starting?
hdrstart = LOC(3)
' Size of the new driver
wSize = LOF(2)
' End of the driver in the file (header size is 32 + 4*4 = 48 bytes)
lNextDriver = hdrstart + wSize + 48

PUT #3, , szName$
' Pad with zeros
zeropad$ = STRING$(hdrstart + 32 - LOC(3), 0)
PUT #3, , zeropad$
PUT #3, , lNextDriver
PUT #3, , wSize
PUT #3, , wDeviceID
' Our wDeviceID is 16-bit, but it needs to be 32-bit - pad with zeros
DIM zero AS INTEGER
zero = 0
PUT #3, , zero
PUT #3, , wExtenderType
' Ditto
PUT #3, , zero
PRINT "New driver header written"

' Buffered read/write of the driver into the new file
WHILE LOC(2) <= (wSize - buflen)
	GET #2, , buf$
	PUT #3, , buf$
WEND
rembytes = wSize - LOC(2)
IF rembytes > 0 THEN
	rembuf$ = SPACE$(rembytes)
	GET #2, , rembuf$
	PUT #3, , rembuf$
END IF
PRINT "All done!"

' Tidy up
CLOSE (1)
CLOSE (2)
CLOSE (3)

SYSTEM

