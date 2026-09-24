/***************************************************************************

    file                 : track.cpp
    created              : Sun Jan 30 22:54:56 CET 2000
    copyright            : (C) 2000 by Eric Espie
    email                : torcs@free.fr
    version              : $Id$

 ***************************************************************************/

/***************************************************************************
 *                                                                         *
 *   This program is free software; you can redistribute it and/or modify  *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 ***************************************************************************/


	graphic->background = GfParmGetStr(TrackHandle, TRK_SECT_GRAPH, TRK_ATT_BKGRND,
						"background.png");
	graphic->bgtype = (int)GfParmGetNum(TrackHandle, TRK_SECT_GRAPH, TRK_ATT_BGTYPE, (char*)NULL, 0.0);
/*     if (graphic->bgtype > 2) { */
/* 	graphic->background2 = GfParmGetStr(TrackHandle, TRK_SECT_GRAPH, TRK_ATT_BKGRND2, */
/* 					    "background.png"); */
/*     } */
	graphic->bgColor[0] = (float)GfParmGetNum(TrackHandle, TRK_SECT_GRAPH, TRK_ATT_BGCLR_R, (char*)NULL, 0.0f);
	graphic->bgColor[1] = (float)GfParmGetNum(TrackHandle, TRK_SECT_GRAPH, TRK_ATT_BGCLR_G, (char*)NULL, 0.0f);
	graphic->bgColor[2] = (float)GfParmGetNum(TrackHandle, TRK_SECT_GRAPH, TRK_ATT_BGCLR_B, (char*)NULL, 0.1f);
	
