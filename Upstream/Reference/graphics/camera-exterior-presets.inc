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

    /* cam F3 = car behind*/
    cam = new cGrCarCamBehind2(myscreen,
			       id,
			       1,	/* drawCurr */
			       1,	/* drawBG  */
			       40.0,	/* fovy */
			       5.0,	/* fovymin */
			       95.0,	/* fovymax */
			       30.0,	/* dist */
			       1.0,	/* near */
			       1000.0 * fovFactor,	/* far */
			       500.0 * fovFactor,	/* fog */
			       1000.0 * fovFactor	/* fog */
			       );
    cam->add(&cams[c]);
    id++;

    /* cam F3 = car behind*/
    cam = new cGrCarCamBehind(myscreen,
			      id,
			      1,	/* drawCurr */
			      1,	/* drawBG  */
			      40.0,	/* fovy */
			      5.0,	/* fovymin */
			      95.0,	/* fovymax */
			      8.0,	/* dist */
			      .50,	/* height */
			      .50,	/* near */
			      600.0 * fovFactor,	/* far */
			      300.0 * fovFactor,	/* fog */
			      600.0 * fovFactor	/* fog */
			      );
    cam->add(&cams[c]);
    id++;

    /* cam F3 = car reverse*/
    cam = new cGrCarCamFront(myscreen,
			     id,
			     1,	/* drawCurr */
			     1,	/* drawBG  */
			     40.0,	/* fovy */
			     5.0,	/* fovymin */
			     95.0,	/* fovymax */
			     8.0,	/* dist */
			     0.5,	/* near */
			     1000.0 * fovFactor,	/* far */
			     500.0 * fovFactor,	/* fog */
			     1000.0 * fovFactor	/* fog */
			     );
    cam->add(&cams[c]);

    /* F4 */
    c++;
    GF_TAILQ_INIT(&cams[c]);
    id = 0;

    /* cam F4 = car side 1*/
    cam = new cGrCarCamSide(myscreen,
			    id,
			    1,	/* drawCurr */
			    1,	/* drawBG  */
			    30.0,	/* fovy */
			    5.0,	/* fovymin */
			    60.0,	/* fovymax */
			    0.0,	/* distx */
			    -20.0,	/* disty */
			    3.0,	/* distz */
			    1.0,	/* near */
			    1000.0 * fovFactor,	/* far */
			    500.0 * fovFactor,	/* fog */
			    1000.0 * fovFactor	/* fog */
			    );
    cam->add(&cams[c]);
    id++;

    /* cam F4 = car side 2*/
    cam = new cGrCarCamSide(myscreen,
			    id,
			    1,	/* drawCurr */
			    1,	/* drawBG  */
			    30.0,	/* fovy */
			    5.0,	/* fovymin */
			    60.0,	/* fovymax */
			    0.0,	/* distx */
			    20.0,	/* disty */
			    3.0,	/* distz */
			    1.0,	/* near */
			    1000.0 * fovFactor,	/* far */
			    500.0 * fovFactor,	/* fog */
			    1000.0 * fovFactor	/* fog */
			    );
    cam->add(&cams[c]);
    id++;

    /* cam F4 = car side 3*/
    cam = new cGrCarCamSide(myscreen,
			    id,
			    1,	/* drawCurr */
			    1,	/* drawBG  */
			    30.0,	/* fovy */
			    5.0,	/* fovymin */
			    60.0,	/* fovymax */
			    -20.0,	/* distx */
			    0.0,	/* disty */
			    3.0,	/* distz */
			    1.0,	/* near */
			    1000.0 * fovFactor,	/* far */
			    500.0 * fovFactor,	/* fog */
			    1000.0 * fovFactor	/* fog */
			    );
    cam->add(&cams[c]);
    id++;

    /* cam F4 = car side 4*/
    cam = new cGrCarCamSide(myscreen,
			    id,
			    1,	/* drawCurr */
			    1,	/* drawBG  */
			    30.0,	/* fovy */
			    5.0,	/* fovymin */
			    60.0,	/* fovymax */
			    20.0,	/* distx */
			    0.0,	/* disty */
			    3.0,	/* distz */
			    1.0,	/* near */
			    1000.0 * fovFactor,	/* far */
			    500.0 * fovFactor,	/* fog */
			    1000.0 * fovFactor	/* fog */
			    );
    cam->add(&cams[c]);
    id++;

    /* cam F4 = car side 5*/
    cam = new cGrCarCamSide(myscreen,
			    id,
			    1,	/* drawCurr */
			    1,	/* drawBG  */
			    30.0,	/* fovy */
			    5.0,	/* fovymin */
			    60.0,	/* fovymax */
			    0.0,	/* distx */
			    -40.0,	/* disty */
			    6.0,	/* distz */
			    1.0,	/* near */
			    1000.0 * fovFactor,	/* far */
			    500.0 * fovFactor,	/* fog */
			    1000.0 * fovFactor	/* fog */
			    );
    cam->add(&cams[c]);
    id++;

    /* cam F4 = car side 6*/
    cam = new cGrCarCamSide(myscreen,
			    id,
			    1,	/* drawCurr */
			    1,	/* drawBG  */
			    30.0,	/* fovy */
			    5.0,	/* fovymin */
			    60.0,	/* fovymax */
			    0.0,	/* distx */
			    40.0,	/* disty */
			    6.0,	/* distz */
			    1.0,	/* near */
			    1000.0 * fovFactor,	/* far */
			    500.0 * fovFactor,	/* fog */
			    1000.0 * fovFactor	/* fog */
			    );
    cam->add(&cams[c]);
    id++;

    /* cam F4 = car side 7*/
    cam = new cGrCarCamSide(myscreen,
			    id,
			    1,	/* drawCurr */
			    1,	/* drawBG  */
			    30.0,	/* fovy */
			    5.0,	/* fovymin */
			    60.0,	/* fovymax */
			    -40.0,	/* distx */
			    0.0,	/* disty */
			    6.0,	/* distz */
			    1.0,	/* near */
			    1000.0 * fovFactor,	/* far */
			    500.0 * fovFactor,	/* fog */
			    1000.0 * fovFactor	/* fog */
			    );
    cam->add(&cams[c]);
    id++;

    /* cam F4 = car side 8*/
    cam = new cGrCarCamSide(myscreen,
			    id,
			    1,	/* drawCurr */
			    1,	/* drawBG  */
			    30.0,	/* fovy */
			    5.0,	/* fovymin */
			    60.0,	/* fovymax */
			    40.0,	/* distx */
			    0.0,	/* disty */
			    6.0,	/* distz */
			    1.0,	/* near */
			    1000.0 * fovFactor,	/* far */
			    500.0 * fovFactor,	/* fog */
			    1000.0 * fovFactor	/* fog */
			    );
    cam->add(&cams[c]);

    /* F5 */
    c++;
    GF_TAILQ_INIT(&cams[c]);
    id = 0;

    /* cam F5 = car up 1*/
    cam = new cGrCarCamUp(myscreen,
			  id,
			  1,	/* drawCurr */
			  1,	/* drawBG  */
			  //12.0,	/* fovy */
			  67.5,	/* fovy */
			  1.0,	/* fovymin */
			  90.0,	/* fovymax */
			  //300.0,	/* distz */
			  200.0,	/* distz */
			  0,		/* axis */
			  //200.0,	/* near */
			  100.0,	/* near */
			  1000.0 * fovFactor,/* far */
			  500.0 * fovFactor,	/* fog */
			  1000.0 * fovFactor	/* fog */
			  );
    cam->add(&cams[c]);
    id++;

    /* cam F5 = car up 2*/
    cam = new cGrCarCamUp(myscreen,
			  id,
			  1,	/* drawCurr */
			  1,	/* drawBG  */
			  //12.0,	/* fovy */
			  67.5,	/* fovy */
			  1.0,	/* fovymin */
			  90.0,	/* fovymax */
			  //300.0,	/* distz */
			  250.0,	/* distz */
			  1,		/* axis */
			  200.0,	/* near */
			  1000.0 * fovFactor,/* far */
			  500.0 * fovFactor,	/* fog */
			  1000.0 * fovFactor	/* fog */
			  );
    cam->add(&cams[c]);
    id++;

    /* cam F5 = car up 3*/
    cam = new cGrCarCamUp(myscreen,
			  id,
			  1,	/* drawCurr */
			  1,	/* drawBG  */
			  //12.0,	/* fovy */
			  67.5,	/* fovy */
			  1.0,	/* fovymin */
			  90.0,	/* fovymax */
			  //300.0,	/* distz */
			  350.0,	/* distz */
			  2,		/* axis */
			  200.0,	/* near */
			  1000.0 * fovFactor,/* far */
			  500.0 * fovFactor,	/* fog */
			  1000.0 * fovFactor	/* fog */
			  );
    cam->add(&cams[c]);
    id++;

    /* cam F5 = car up 4*/
    cam = new cGrCarCamUp(myscreen,
			  id,
			  1,	/* drawCurr */
			  1,	/* drawBG  */
			  //12.0,	/* fovy */
			  67.5,	/* fovy */
			  1.0,	/* fovymin */
			  90.0,	/* fovymax */
			  //300.0,	/* distz */
			  400.0,	/* distz */
			  3,		/* axis */
			  200.0,	/* near */
			  1000.0 * fovFactor,/* far */
			  500.0 * fovFactor,	/* fog */
			  1000.0 * fovFactor	/* fog */
			  );
    cam->add(&cams[c]);

