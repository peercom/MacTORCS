/***************************************************************************

    file        : raceresults.cpp
    created     : Thu Jan  2 12:43:10 CET 2003
    copyright   : (C) 2002, 2017 by Eric Espie, Bernhard Wymann                        
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
    Processing of race results		
    @author	Bernhard Wymann, Eric Espie
    @version $Id$
*/

		case RM_TYPE_QUALIF:
			car = s->cars[0];
			snprintf(path, BUFSIZE, "%s/%s/%s/%s", ReInfo->track->name, RE_SECT_RESULTS, race, RE_SECT_RANK);
			nCars = GfParmGetEltNb(results, path);
			for (i = nCars; i > 0; i--) {
				snprintf(path, BUFSIZE, "%s/%s/%s/%s/%d", ReInfo->track->name, RE_SECT_RESULTS, race, RE_SECT_RANK, i);
				float opponentBestLapTime = GfParmGetNum(results, path, RE_ATTR_BEST_LAP_TIME, NULL, 0);
			
				if (
					(car->_bestLapTime != 0.0) && 
					((round(car->_bestLapTime*1000.0f) < round(opponentBestLapTime*1000.0f)) || (opponentBestLapTime == 0.0))
				) {
					/* shift */
					snprintf(path2, BUFSIZE, "%s/%s/%s/%s/%d", ReInfo->track->name, RE_SECT_RESULTS, race, RE_SECT_RANK, i + 1);
					GfParmSetStr(results, path2, RE_ATTR_NAME, GfParmGetStr(results, path, RE_ATTR_NAME, ""));
					GfParmSetStr(results, path2, RE_ATTR_CAR, GfParmGetStr(results, path, RE_ATTR_CAR, ""));
					GfParmSetNum(results, path2, RE_ATTR_BEST_LAP_TIME, NULL, GfParmGetNum(results, path, RE_ATTR_BEST_LAP_TIME, NULL, 0));
					GfParmSetStr(results, path2, RE_ATTR_MODULE, GfParmGetStr(results, path, RM_ATTR_MODULE, ""));
					GfParmSetNum(results, path2, RE_ATTR_IDX, NULL, GfParmGetNum(results, path, RM_ATTR_IDX, NULL, 0));
					snprintf(path, BUFSIZE, "%s/%s/%d", race, RM_SECT_POINTS, i + 1);
					GfParmSetNum(results, path2, RE_ATTR_POINTS, NULL,
								(int)GfParmGetNum(params, path, RE_ATTR_POINTS, NULL, 0));
				} else {
					break;
				}
			}
			/* insert after */
			snprintf(path, BUFSIZE, "%s/%s/%s/%s/%d", ReInfo->track->name, RE_SECT_RESULTS, race, RE_SECT_RANK, i + 1);
			GfParmSetStr(results, path, RE_ATTR_NAME, car->_name);
			
			snprintf(buf, BUFSIZE, "cars/%s/%s.xml", car->_carName, car->_carName);
			carparam = GfParmReadFile(buf, GFPARM_RMODE_STD);
			carName = GfParmGetName(carparam);
			
			GfParmSetStr(results, path, RE_ATTR_CAR, carName);
			GfParmSetNum(results, path, RE_ATTR_BEST_LAP_TIME, NULL, round(car->_bestLapTime*1000.0f)/1000.0f);
			GfParmSetStr(results, path, RE_ATTR_MODULE, car->_modName);
			GfParmSetNum(results, path, RE_ATTR_IDX, NULL, car->_driverIndex);
			snprintf(path2, BUFSIZE, "%s/%s/%d", race, RM_SECT_POINTS, i + 1);
			GfParmSetNum(results, path, RE_ATTR_POINTS, NULL,
						(int)GfParmGetNum(params, path2, RE_ATTR_POINTS, NULL, 0));
		
