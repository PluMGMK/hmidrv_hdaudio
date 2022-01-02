/* HMIAPPND.C
   Append new driver(s) to the end of a HMI driver blob
   Written in C since this is really the only sane way to get something running
   on both Unix and DOS, at least at the moment...
   */

#include <stdio.h>
#include <string.h>
#include <stdint.h>

#ifdef __unix__
/* TODO: Find a better define for this?? */
#define stricmp strcasecmp
#define strnicmp strncasecmp
#include <strings.h>
#endif

#define INFILEARG "oldfile="
#define DRVFILEARG "drvfile="
#define OUTFILEARG "newfile="

#define DEVARG "drv"
#define RATIONALCHAR 'r'
#define FLASHTEKCHAR 'f'
#define BOTHEXTCHAR 'b'

#define MINDEVID 0xE000
#define MAXDEVID 0xE200

#define EXT_FLASHTEK 0x4000
#define EXT_RATIONAL 0x8000

#define COPYBUF_SIZE 0x1000 /* One page... */
char copy_buffer[COPYBUF_SIZE]; /* Too big for stack! */

int main(int argc, char **argv, const char **envp) {
	char *infile = NULL, *outfile = NULL;
	uint32_t wDeviceID = 0, wExtenderType = EXT_RATIONAL;

	/* Declarations for later... */
	char szName[32], drvfile[32], drvtype;
	long copy_filesize;
	uint32_t hdrstart, wDrivers, lNextDriver, wSize;
	FILE *inhdl, *outhdl, *drvhdl;

	int drvstoappend = 0;
	int i;	
	for(i = 0; i < argc; i++) {
		if(!strnicmp(argv[i], INFILEARG, strlen(INFILEARG)))
			infile = argv[i] + strlen(INFILEARG);
		else if(!strnicmp(argv[i], OUTFILEARG, strlen(OUTFILEARG)))
			outfile = argv[i] + strlen(OUTFILEARG);
		else if(sscanf(argv[i], DEVARG"%c:%4x=%31s",
				&drvtype, &wDeviceID, drvfile) == 3
				&& (drvtype == RATIONALCHAR ||
				drvtype == FLASHTEKCHAR ||
				drvtype == BOTHEXTCHAR)
				&& wDeviceID>=MINDEVID && wDeviceID<=MAXDEVID)
			drvstoappend++;
	}

	if(infile == NULL || outfile == NULL || !drvstoappend) {
		printf("Usage:\t%s"
			" \\\n\t%s<Input HMIDRV.386 file>"
			" \\\n\t%s<Output HMIDRV.386 file>"
			" \\\n\t%s[%c|%c|%c]:<Device ID>=<Device BIN file>"
			"\nYou can specify as many device files as needed."
			"\nThe %dth character of each argument specifies the DOS extender type:"
			"\n\tRational, FlashTek, or both."
			"\nValid Device IDs are from %4X to %4X.\n",
			argv[0],
			INFILEARG, OUTFILEARG,
			DEVARG, RATIONALCHAR, FLASHTEKCHAR, BOTHEXTCHAR,
			strlen(DEVARG) + 1,
			MINDEVID, MAXDEVID);
		return 1;
	}

	inhdl = fopen(infile, "rb");
	if(!inhdl) {
		perror("Coudn't open input file");
		return -1;
	}

	outhdl = fopen(outfile, "wb");
	if(!outhdl) {
		perror("Coudn't open output file");
		return -1;
	}

	/* Copy over the "szName" field of the file header */
	fread(szName, sizeof(char), 32, inhdl);
	fwrite(szName, sizeof(char), 32, outhdl);

	/* Number of drivers in the file */
	fread(&wDrivers, sizeof(uint32_t), 1, inhdl);
	/* wDrivers += drvstoappend; */
	fwrite(&wDrivers, sizeof(uint32_t), 1, outhdl);

	printf("szName and wDrivers written...\n");

	/* Figure out how much stuff to copy to the new file */
	fseek(inhdl, 0, SEEK_END);
	copy_filesize = ftell(inhdl);
	fseek(inhdl, ftell(outhdl), SEEK_SET); /* Back to where we were... */

	/* Copy it */
	while(ftell(inhdl) < copy_filesize)
		fwrite(copy_buffer, sizeof(char),
			fread(copy_buffer, sizeof(char), COPYBUF_SIZE, inhdl),
			outhdl);
	printf("Old HMIDRV file copied to new one\n");

	for(i = 0; i < argc && drvstoappend; i++) {
		if(sscanf(argv[i], DEVARG"%c:%4x=%31s",
			&drvtype, &wDeviceID, drvfile) < 3)
			continue;

		switch(drvtype) {
			case RATIONALCHAR:
				wExtenderType = EXT_RATIONAL;
				break;
			case FLASHTEKCHAR:
				wExtenderType = EXT_FLASHTEK;
				break;
			case BOTHEXTCHAR:
				wExtenderType = EXT_RATIONAL | EXT_FLASHTEK;
				break;
			default:
				continue;
		}

		if(wDeviceID < MINDEVID || wDeviceID > MAXDEVID)
			continue;

		printf("\nProcessing argument '%s'\n", argv[i]);

		drvhdl = fopen(drvfile, "rb");
		if(!drvhdl) {
			perror("Couldn't open driver file");
			continue;
		}

		/* Construct the new driver header */
		/* Where is the current header starting? */
		hdrstart = ftell(outhdl);
		/* Size of the new driver */
		fseek(drvhdl, 0, SEEK_END);
		wSize = ftell(drvhdl);
		fseek(drvhdl, 0, SEEK_SET);
		/* End of the driver in the file
		   (header size is 32 + 4*4 = 48 bytes) */
		lNextDriver = hdrstart + wSize + 48;

		memset(szName, 0, 32); /* Make sure it's null-padded */
		strncpy(szName, drvfile, 32);
		fwrite(szName, sizeof(char), 32, outhdl);
		fwrite(&lNextDriver, sizeof(uint32_t), 1, outhdl);
		fwrite(&wSize, sizeof(uint32_t), 1, outhdl);
		fwrite(&wDeviceID, sizeof(uint32_t), 1, outhdl);
		fwrite(&wExtenderType, sizeof(uint32_t), 1, outhdl);
		printf("New driver header written\n");

		/* Copy it */
		while(ftell(drvhdl) < wSize) 
			fwrite(copy_buffer, sizeof(char),
				fread(copy_buffer, sizeof(char), COPYBUF_SIZE, drvhdl),
				outhdl);
		printf("Data copied!\n");

		fclose(drvhdl);

		wDrivers++;
		drvstoappend--;
	}

	/* Write the updated wDrivers into the output file header */
	fseek(outhdl, 32, SEEK_SET);
	fwrite(&wDrivers, sizeof(uint32_t), 1, outhdl);

	printf("\nAll done!\n");
	return 0;
}

