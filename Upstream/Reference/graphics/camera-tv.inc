/***************************************************************************

    file                 : grcam.cpp
    created              : Mon Aug 21 20:55:32 CEST 2000
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

static tdble
GetDistToStart(tCarElt *car)
{
    tTrackSeg	*seg;
    tdble	lg;
    
    seg = car->_trkPos.seg;
    lg = seg->lgfromstart;
    
    switch (seg->type) {
    case TR_STR:
	lg += car->_trkPos.toStart;
	break;
    default:
	lg += car->_trkPos.toStart * seg->radius;
	break;
    }
    return lg;
}

typedef struct 
{
    double	prio;
    int		viewable;
    int		event;
} tSchedView;

class cGrCarCamRoadZoomTVD : public cGrCarCamRoadZoom
{
    tSchedView *schedView;
    double camChangeInterval;
    double camEventInterval;
    double lastEventTime;
    double lastViewTime;
    tdble  proximityThld;
    int		current;

 public:
    cGrCarCamRoadZoomTVD(class cGrScreen *myscreen, int id, int drawCurr, int drawBG,
			 float fovy, float fovymin, float fovymax,
			 float fnear, float ffar = 1500.0,
			 float myfogstart = 1400.0, float myfogend = 1500.0)
	: cGrCarCamRoadZoom(myscreen, id, drawCurr, drawBG, fovy, fovymin,
			    fovymax, fnear, ffar, myfogstart, myfogend) {
	schedView = (tSchedView *)calloc(grNbCars, sizeof(tSchedView));
	if (!schedView) {
	    GfTrace("malloc error");
	    GfScrShutdown();
	    exit (1);
	}
    
	lastEventTime = 0;
	lastViewTime = 0;

	current = -1;

	camChangeInterval = GfParmGetNum(grHandle, GR_SCT_TVDIR, GR_ATT_CHGCAMINT, (char*)NULL, 10.0);
	camEventInterval  = GfParmGetNum(grHandle, GR_SCT_TVDIR, GR_ATT_EVTINT, (char*)NULL, 1.0);
	proximityThld     = GfParmGetNum(grHandle, GR_SCT_TVDIR, GR_ATT_PROXTHLD, (char*)NULL, 10.0);
    }

    ~cGrCarCamRoadZoomTVD() { free(schedView); }

    void update(tCarElt *car, tSituation *s) {
	int	i, j;
	int	curCar;
	double	curPrio;
	double	deltaEventTime = s->currentTime - lastEventTime;
	double	deltaViewTime = s->currentTime - lastViewTime;
	int	event = 0;

	if (current == -1) {
	    current = 0;
	    for (i = 0; i < grNbCars; i++) {
		if (car == s->cars[i]) {
		    current = i;
		    break;
		}
	    }
	}
	
    
	/* Track events */
	if (deltaEventTime > camEventInterval) {

	    memset(schedView, 0, grNbCars * sizeof(tSchedView));
	    for (i = 0; i < grNbCars; i++) {
		schedView[i].viewable = 1;
	    }
	    
	    for (i = 0; i < GR_NB_MAX_SCREEN; i++) {
		if ((screen != grScreens[i]) && grScreens[i]->isActive()) {
		    car = grScreens[i]->getCurrentCar();
		    schedView[car->index].viewable = 0;
		    schedView[car->index].prio -= 10000;
		}
	    }
	    
	    for (i = 0; i < grNbCars; i++) {
		tdble dist, fs;

		car = s->cars[i];
		schedView[car->index].prio += grNbCars - i;
		fs = GetDistToStart(car);
		if ((car->_state & RM_CAR_STATE_NO_SIMU) != 0) {
		    schedView[car->index].viewable = 0;
		} else {
		    if ((fs > (grTrack->length - 200.0)) && (car->_remainingLaps == 0)) {
			schedView[car->index].prio += 5 * grNbCars;
			event = 1;
		    }
		}
	
		if ((car->_state & RM_CAR_STATE_NO_SIMU) == 0) {
		    dist = fabs(car->_trkPos.toMiddle) - grTrack->width / 2.0;
		    /* out of track */
		    if (dist > 0) {
			schedView[car->index].prio += grNbCars;
			if (car->ctrl.raceCmd & RM_CMD_PIT_ASKED) {
			    schedView[car->index].prio += grNbCars;
			    event = 1;
			}
		    }

		    for (j = i+1; j < grNbCars; j++) {
			tCarElt *car2 = s->cars[j];
			tdble fs2 = GetDistToStart(car2);
			tdble d = fabs(fs2 - fs);

			if ((car2->_state & RM_CAR_STATE_NO_SIMU) == 0) {
			    if (d < proximityThld) {
				d = proximityThld - d;
				schedView[car->index].prio  += d * grNbCars / proximityThld;
				schedView[car2->index].prio += d * (grNbCars - 1) / proximityThld;
				if (i == 0) {
				    event = 1;
				}
			    }
			}
		    }

		    if (car->priv.collision) {
			schedView[car->index].prio += grNbCars;
			event = 1;
		    }
		} else {
		    if (i == current) {
			event = 1;	/* update view */
		    }
		}
	    }


	    /* change current car */
	    if ((event && (deltaEventTime > camEventInterval)) || (deltaViewTime > camChangeInterval)) {
		int	last_current = current;

		curCar = 0;
		curPrio = -1000000.0;
		for (i = 0; i < grNbCars; i++) {
	    
		    if ((schedView[i].prio > curPrio) && (schedView[i].viewable)) {
			curPrio = schedView[i].prio;
			curCar = i;
		    }
		}
		for (i = 0; i < grNbCars; i++) {
		    if (s->cars[i]->index == curCar) {
			current = i;
			break;
		    }
		}
		if (last_current != current) {
		    lastEventTime = s->currentTime;
		    lastViewTime = s->currentTime;

		    for (i = 0; i < grNbCars; i++) {
			s->cars[i]->priv.collision = 0;
		    }
		}
	    }
	}

	screen->setCurrentCar(s->cars[current]);
	
	cGrCarCamRoadZoom::update(s->cars[current], s);
    }
};
