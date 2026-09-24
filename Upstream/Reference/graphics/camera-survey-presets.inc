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

