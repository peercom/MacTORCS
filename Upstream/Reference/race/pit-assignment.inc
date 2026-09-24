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
initPits(void)
{
	tTrackPitInfo *pits;
	int i, j;

	/*
	typedef std::map<std::string, int> tTeamsMap;
	typedef tTeamsMap::const_iterator tTeamsMapIterator;
	tTeamsMap teams;
	tTeamsMapIterator teamsIterator;

	// create a list with the teams, a pit can just be used by one team.
	for (i = 0; i < ReInfo->s->_ncars; i++) {
		tCarElt *car = &(ReInfo->carList[i]);
		teams[car->_teamname] = teams[car->_teamname] + 1; 
	}	

	for (teamsIterator = teams.begin(); teamsIterator != teams.end(); ++teamsIterator) {
		printf("----------------- %s\t%d\n", (teamsIterator->first).c_str(), teamsIterator->second); 
	}
	*/

	// How many cars are sharing a pit?
	int carsPerPit = (int) GfParmGetNum(ReInfo->params, ReInfo->_reRaceName, RM_ATTR_CARSPERPIT, NULL, 1.0f);
	if (carsPerPit < 1) {
		carsPerPit = 1;
	} else if (carsPerPit > TR_PIT_MAXCARPERPIT) {
		carsPerPit = TR_PIT_MAXCARPERPIT;
	}
	GfOut("Cars per pit: %d\n", carsPerPit);

	switch (ReInfo->track->pits.type) {
		case TR_PIT_ON_TRACK_SIDE:
			pits = &(ReInfo->track->pits);
			pits->driversPitsNb = ReInfo->s->_ncars;
			pits->carsPerPit = carsPerPit;

			// Initialize pit data for every pit, necessary because of restarts
			// (track gets not reloaded, no calloc).
			for (i = 0; i < pits->nMaxPits; i++) {
				tTrackOwnPit *pit = &(pits->driversPits[i]);
				pit->freeCarIndex = 0;
				pit->pitCarIndex = TR_PIT_STATE_FREE;
				for (j = 0; j < TR_PIT_MAXCARPERPIT; j++) {
					pit->car[j] = NULL;
				}
			}

			// Assign cars to pits. Inefficient (O(n*n)), but just at initialization, so do not care.
			// One pit can just host cars of one team (this matches with the reality) 
			for (i = 0; i < ReInfo->s->_ncars; i++) {
				// Find pit for the cars team.
				tCarElt *car = &(ReInfo->carList[i]);
				for (j = 0; j < pits->nMaxPits; j++) {
					tTrackOwnPit *pit = &(pits->driversPits[j]);
					// Put car in this pit if the pit is unused or used by a teammate and there is
					// space left.
					if (pit->freeCarIndex <= 0 ||
						(strcmp(pit->car[0]->_teamname, car->_teamname) == 0 && pit->freeCarIndex < carsPerPit))
					{
						// Assign car to pit.
						pit->car[pit->freeCarIndex] = car;
						// If this is the first car set up more pit values, assumtion: the whole team
						// uses the same car. If not met it does not matter much, but the car might be
						// captured a bit too easy or too hard.
						if (pit->freeCarIndex == 0) {
							pit->pitCarIndex = TR_PIT_STATE_FREE;
							pit->lmin = pit->pos.seg->lgfromstart + pit->pos.toStart - pits->len / 2.0 + car->_dimension_x / 2.0;
							if (pit->lmin > ReInfo->track->length) {
								pit->lmin -= ReInfo->track->length;
							}
							pit->lmax = pit->pos.seg->lgfromstart + pit->pos.toStart + pits->len / 2.0 - car->_dimension_x / 2.0;
							if (pit->lmax > ReInfo->track->length) {
								pit->lmax -= ReInfo->track->length;
							}
						}
						(pit->freeCarIndex)++;
						ReInfo->carList[i]._pit = pit;
						// Assigned, continue with next car.
						break;
					}
				}
			}

			// Print out assignments.
			for (i = 0; i < pits->nMaxPits; i++) {
				tTrackOwnPit *pit = &(pits->driversPits[i]);
				for (j = 0; j < pit->freeCarIndex; j++) {
					if (j == 0) {
						GfOut("Pit %d, Team: %s, ", i, pit->car[j]->_teamname); 
					}
					GfOut("%d: %s ", j, pit->car[j]->_name);
				}
				if (j > 0) {
					GfOut("\n");
				}
			}

			break;
		case TR_PIT_ON_SEPARATE_PATH:
			break;
		case TR_PIT_NONE:
			break;
	}
}
