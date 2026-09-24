/***************************************************************************

    file                 : grutil.cpp
    created              : Wed Nov  1 21:33:22 CET 2000
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

float grGetHOT(float x, float y)
{
	sgVec3 test_vec;
	sgMat4 invmat;
	sgMakeIdentMat4(invmat);

	invmat[3][0] = -x;
	invmat[3][1] = -y;
	invmat[3][2] =  0.0f         ;

	test_vec [0] = 0;
	test_vec [1] = 0;
	test_vec [2] = 100000.0f;

	ssgHit *results;
	int num_hits = ssgHOT (TheScene, test_vec, invmat, &results);
	float hot = -1000000.0f;

	for (int i = 0; i < num_hits; i++) {
		ssgHit *h = &results[i];

		float hgt = (h->plane[2] == 0.0 ? 0.0 : - h->plane[3] / h->plane[2]);

		if (hgt >= hot) {
			hot = hgt;
		}
	}

	return hot;
}



