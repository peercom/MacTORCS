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

    /* F2 */
    GF_TAILQ_INIT(&cams[c]);
    id = 0;
    
    /* cam F2 = behind very near */
    cam = new cGrCarCamBehind(myscreen,
			      id,
			      1,	/* drawCurr */
			      1,	/* drawBG  */
			      40.0,	/* fovy */
			      5.0,	/* fovymin */
			      95.0,	/* fovymax */
			      6.0,	/* dist */
			      2.0,	/* height */
			      1.0,	/* near */
			      600.0 * fovFactor,	/* far */
			      300.0 * fovFactor,	/* fog */
			      600.0 * fovFactor	/* fog */
			      );
    cam->add(&cams[c]);
    id++;
    
    /* cam F2 = behind near */
    cam = new cGrCarCamBehind(myscreen,
			      id,
			      1,	/* drawCurr */
			      1,	/* drawBG  */
			      40.0,	/* fovy */
			      5.0,	/* fovymin */
			      95.0,	/* fovymax */
			      10.0,	/* dist */
			      2.0,	/* height */
			      1.0,	/* near */
			      600.0 * fovFactor,	/* far */
			      300.0 * fovFactor,	/* fog */
			      600.0 * fovFactor	/* fog */
			      );
    cam->add(&cams[c]);
    id++;
    
    /* cam F2 = car inside with car (bonnet view) fixed to the car */
    cam = new cGrCarCamInsideFixedCar(myscreen,
				      id,
				      1,	/* drawCurr */
				      1,	/* drawBG  */
				      67.5,	/* fovy */
				      50.0,	/* fovymin */
				      95.0,	/* fovymax */
				      0.3,	/* near */
				      600.0 * fovFactor,	/* far */
				      300.0 * fovFactor,	/* fog */
				      600.0 * fovFactor	/* fog */
				      );
    cam->add(&cams[c]);
    id++;
    
    /* cam F2 = car inside with car (bonnet view) */
    cam = new cGrCarCamInside(myscreen,
			      id,
			      1,	/* drawCurr */
			      1,	/* drawBG  */
			      67.5,	/* fovy */
			      50.0,	/* fovymin */
			      95.0,	/* fovymax */
			      0.1,	/* near */
			      600.0 * fovFactor,	/* far */
			      300.0 * fovFactor,	/* fog */
			      600.0 * fovFactor	/* fog */
			      );
    cam->add(&cams[c]);
    id++;

    /* cam F2 = car inside car (no car - road view) */
    cam = new cGrCarCamInsideFixedCar(myscreen,
				      id,
				      0,	/* drawCurr */
				      1,	/* drawBG  */
				      67.5,	/* fovy */
				      50.0,	/* fovymin */
				      95.0,	/* fovymax */
				      0.3,	/* near */
				      600.0 * fovFactor,	/* far */
				      300.0 * fovFactor,	/* fog */
				      600.0 * fovFactor	/* fog */
				      );
    cam->add(&cams[c]);

    /* F3 */
    c++;
    GF_TAILQ_INIT(&cams[c]);
    id = 0;
    
    /* cam F3 = behind far */
    cam = new cGrCarCamBehind(myscreen,
			      id,
			      1,	/* drawCurr */
			      1,	/* drawBG  */
			      40.0,	/* fovy */
			      5.0,	/* fovymin */
			      95.0,	/* fovymax */
			      20.0,	/* dist */
			      2.0,	/* height */
			      1.0,	/* near */
			      600.0 * fovFactor,	/* far */
			      300.0 * fovFactor,	/* fog */
			      600.0 * fovFactor	/* fog */
			      );
    cam->add(&cams[c]);
    id++;

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

    /* F6 */
    c++;
    GF_TAILQ_INIT(&cams[c]);
    id = 0;

    /* cam F6 = car from circuit centre */
    cam = new cGrCarCamCenter(myscreen,
			      id,
			      1,	/* drawCurr */
			      1,	/* drawBG  */
			      21.0,	/* fovy */
			      2.0,	/* fovymin */
			      60.0,	/* fovymax */
			      120.0,	/* distz */
			      100.0,	/* near */
			      1500.0,/* far */
			      10500.0,/* fog */
			      20500.0	/* fog */
			      );
    cam->add(&cams[c]);

    /* F7 */
    c++;
    GF_TAILQ_INIT(&cams[c]);
    id = 0;

    /* cam F7 = panoramic */
    cam = new cGrCarCamLookAt(myscreen,
			      id,
			      1,		/* drawCurr */
			      0,		/* drawBG  */
			      74.0,		/* fovy */
			      1.0,		/* fovymin */
			      110.0,		/* fovymax */
			      0,		/* up axis */
			      grWrldX/2,	/* eyex */
			      grWrldY/2,	/* eyey */
			      MAX(grWrldX/2, grWrldY*4/3/2) + grWrldZ, /* eyez */
			      grWrldX/2,	/* centerx */
			      grWrldY/2,	/* centery */
			      0,		/* centerz */
			      10.0,		/* near */
			      grWrldMaxSize * 2.0,	/* far */
			      grWrldMaxSize * 10.0,	/* fog */
			      grWrldMaxSize * 20.0	/* fog */
			      );
    cam->add(&cams[c]);
    id++;

    /* cam F7 = panoramic */
    cam = new cGrCarCamLookAt(myscreen,
			      id,
			      1,		/* drawCurr */
			      0,		/* drawBG  */
			      74.0f,		/* fovy */
			      1.0f,		/* fovymin */
			      110.0f,		/* fovymax */
			      4,		/* up axis */
			      -grWrldX/2.0f,	/* eyex */
			      -grWrldY/2.0f,	/* eyey */
			      0.25f * sqrt((double)(grWrldX*grWrldX+grWrldY*grWrldY)), /* eyez */
			      grWrldX/2.0f,	/* centerx */
			      grWrldY/2.0f,	/* centery */
			      0.0f,		/* centerz */
			      10.0f,		/* near */
			      2.0f * grWrldMaxSize,	/* far */
			      10.0f * grWrldMaxSize,	/* fog */
			      20.0f * grWrldMaxSize	/* fog */
			      );
    cam->add(&cams[c]);
    id++;

    /* cam F7 = panoramic */
    cam = new cGrCarCamLookAt(myscreen,
			      id,
			      1,		/* drawCurr */
			      0,		/* drawBG  */
			      74.0f,		/* fovy */
			      1.0f,		/* fovymin */
			      110.0f,		/* fovymax */
			      4,		/* up axis */
			      -grWrldX/2.0f,	/* eyex */
			      grWrldY * 3.0f/2.0f,	/* eyey */
			      0.25f * sqrt((double)(grWrldX*grWrldX+grWrldY*grWrldY)), /* eyez */
			      grWrldX/2.0f,	/* centerx */
			      grWrldY/2.0f,	/* centery */
			      0.0f,		/* centerz */
			      10.0f,		/* near */
			      2.0f * grWrldMaxSize,	/* far */
			      10.0f * grWrldMaxSize,	/* fog */
			      20.0f * grWrldMaxSize	/* fog */
			      );
    cam->add(&cams[c]);
    id++;

    /* cam F7 = panoramic */
    cam = new cGrCarCamLookAt(myscreen,
			      id,
			      1,		/* drawCurr */
			      0,		/* drawBG  */
			      74.0f,		/* fovy */
			      1.0f,		/* fovymin */
			      110.0f,		/* fovymax */
			      4,		/* up axis */
			      grWrldX * 3.0f/2.0f,	/* eyex */
			      grWrldY * 3.0f/2.0f,	/* eyey */
			      0.25f * sqrt((double)(grWrldX*grWrldX+grWrldY*grWrldY)), /* eyez */
			      grWrldX/2.0f,	/* centerx */
			      grWrldY/2.0f,	/* centery */
			      0.0f,		/* centerz */
			      10.0f,		/* near */
			      2.0f * grWrldMaxSize,	/* far */
			      10.0f * grWrldMaxSize,	/* fog */
			      20.0f * grWrldMaxSize	/* fog */
			      );
    cam->add(&cams[c]);
    id++;

    /* cam F7 = panoramic */
    cam = new cGrCarCamLookAt(myscreen,
			      id,
			      1,		/* drawCurr */
			      0,		/* drawBG  */
			      74.0f,		/* fovy */
			      1.0f,		/* fovymin */
			      110.0f,		/* fovymax */
			      4,		/* up axis */
			      grWrldX * 3.0f/2.0f,	/* eyex */
			      -grWrldY/2.0f,	/* eyey */
			      0.25f * sqrt((double)(grWrldX*grWrldX+grWrldY*grWrldY)), /* eyez */
			      grWrldX/2.0f,	/* centerx */
			      grWrldY/2.0f,	/* centery */
			      0.0f,		/* centerz */
			      10.0f,		/* near */
			      2.0f * grWrldMaxSize,	/* far */
			      10.0f * grWrldMaxSize,	/* fog */
			      20.0f * grWrldMaxSize	/* fog */
			      );
    cam->add(&cams[c]);
    id++;

    /* F8 */
    c++;
    GF_TAILQ_INIT(&cams[c]);
    id = 0;

    /* cam F8 = road cam fixed fov */

    cam = new cGrCarCamRoadNoZoom(myscreen,
				  id,
				  1,		/* drawCurr */
				  1,		/* drawBG  */
				  30.0,	/* fovy */
				  5.0,	/* fovymin */
				  60.0,	/* fovymax */
				  1.0,	/* near */
				  1000.0 * fovFactor,/* far */
				  500.0 * fovFactor,	/* fog */
				  1000.0 * fovFactor	/* fog */
				  );
    cam->add(&cams[c]);

    /* F9 */
    c++;
    GF_TAILQ_INIT(&cams[c]);
    id = 0;

    /* cam F9 = road cam zoomed */
    cam = new cGrCarCamRoadZoom(myscreen,
				id,
				1,		/* drawCurr */
				1,		/* drawBG  */
				9.0,	/* fovy */
				1.0,		/* fovymin */
				90.0,	/* fovymax */
				1.0,		/* near */
				1000.0 * fovFactor,	/* far */
				500.0 * fovFactor,	/* fog */
				1000.0 * fovFactor	/* fog */
				);
    cam->add(&cams[c]);

