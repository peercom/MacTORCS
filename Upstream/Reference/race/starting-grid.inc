/***************************************************************************

    file        : raceinit.cpp
    created     : Sat Nov 16 10:34:35 CET 2002
    copyright   : (C) 2002-2017 by Eric Espie, Bernhard Wymann                
    email       : eric.espie@torcs.org   
    version     : $Id$                                  

 ***************************************************************************/

/***************************************************************************
 *                                                                         *
 *   This program is free software; you can redistribute it and/or modify  *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 ***************************************************************************/

/** @file   
    		
    @author	<a href=mailto:eric.espie@torcs.org>Eric Espie</a>
    @version	$Id$
*/


/* Race initialization routines */

static void
initStartingGrid(void)
{
	int i;
	tTrackSeg *curseg;
	int rows;
	tdble a, b; //, wi2;
	tdble d1, d2,d3;
	tdble startpos, tr, ts;
	tdble speedInit;
	tdble heightInit;
	tCarElt *car;
	const char *pole;
	void *trHdle = ReInfo->track->params;
	void *params = ReInfo->params;
	const int BUFSIZE = 1024;
	char path[BUFSIZE];

	snprintf(path, BUFSIZE, "%s/%s", ReInfo->_reRaceName, RM_SECT_STARTINGGRID);

	/* Search for the first turn for find the pole side */
	curseg = ReInfo->track->seg->next;
	while (curseg->type == TR_STR) {
		/* skip the straight segments */
		curseg = curseg->next;
	}
	/* Set the pole for the inside of the first turn */
	if (curseg->type == TR_LFT) {
		pole = GfParmGetStr(params, path, RM_ATTR_POLE, "left");
	} else {
		pole = GfParmGetStr(params, path, RM_ATTR_POLE, "right");
	}
	/* Tracks definitions can force the pole side */
	pole = GfParmGetStr(trHdle, RM_SECT_STARTINGGRID, RM_ATTR_POLE, pole);

	if (strcmp(pole, "left") == 0) {
		a = ReInfo->track->width;
		b = -a;
	} else {
		a = 0;
		b = ReInfo->track->width;
	}
	//wi2 = ReInfo->track->width * 0.5;

	rows = (int)GfParmGetNum(params, path, RM_ATTR_ROWS, (char*)NULL, 2);
	rows = (int)GfParmGetNum(trHdle, RM_SECT_STARTINGGRID, RM_ATTR_ROWS, (char*)NULL, rows);
	d1 = GfParmGetNum(params, path, RM_ATTR_TOSTART, (char*)NULL, 10);
	d1 = GfParmGetNum(trHdle, RM_SECT_STARTINGGRID, RM_ATTR_TOSTART, (char*)NULL, d1);
	d2 = GfParmGetNum(params, path, RM_ATTR_COLDIST, (char*)NULL, 10);
	d2 = GfParmGetNum(trHdle, RM_SECT_STARTINGGRID, RM_ATTR_COLDIST, (char*)NULL, d2);
	d3 = GfParmGetNum(params, path, RM_ATTR_COLOFFSET, (char*)NULL, 5);
	d3 = GfParmGetNum(trHdle, RM_SECT_STARTINGGRID, RM_ATTR_COLOFFSET, (char*)NULL, d3);
	speedInit = GfParmGetNum(params, path, RM_ATTR_INITSPEED, (char*)NULL, 0.0);
	heightInit = GfParmGetNum(params, path, RM_ATTR_INITHEIGHT, (char*)NULL, 0.3);
	heightInit = GfParmGetNum(trHdle, RM_SECT_STARTINGGRID, RM_ATTR_INITHEIGHT, (char*)NULL, heightInit);

	if (rows < 1) {
		rows = 1;
	}
	for (i = 0; i < ReInfo->s->_ncars; i++) {
		car = &(ReInfo->carList[i]);
		car->_speed_x = speedInit;
		car->_commitBestLapTime = true;
		startpos = ReInfo->track->length - (d1 + (i / rows) * d2 + (i % rows) * d3);
		tr = a + b * ((i % rows) + 1) / (rows + 1);
		curseg = ReInfo->track->seg;  /* last segment */
		while (startpos < curseg->lgfromstart) {
			curseg = curseg->prev;
		}
		ts = startpos - curseg->lgfromstart;
		car->_trkPos.seg = curseg;
		car->_trkPos.toRight = tr;
		switch (curseg->type) {
			case TR_STR:
				car->_trkPos.toStart = ts;
				RtTrackLocal2Global(&(car->_trkPos), &(car->_pos_X), &(car->_pos_Y), TR_TORIGHT);
				car->_yaw = curseg->angle[TR_ZS];
				break;
			case TR_RGT:
				car->_trkPos.toStart = ts / curseg->radius;
				RtTrackLocal2Global(&(car->_trkPos), &(car->_pos_X), &(car->_pos_Y), TR_TORIGHT);
				car->_yaw = curseg->angle[TR_ZS] - car->_trkPos.toStart;
				break;
			case TR_LFT:
				car->_trkPos.toStart = ts / curseg->radius;
				RtTrackLocal2Global(&(car->_trkPos), &(car->_pos_X), &(car->_pos_Y), TR_TORIGHT);
				car->_yaw = curseg->angle[TR_ZS] + car->_trkPos.toStart;
				break;
		}
		car->_pos_Z = RtTrackHeightL(&(car->_trkPos)) + heightInit;

		NORM0_2PI(car->_yaw);
		ReInfo->_reSimItf.config(car, ReInfo);
	}
}

