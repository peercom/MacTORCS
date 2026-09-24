/***************************************************************************

    file                 : grvtxtable.cpp
    created              : Fri Mar 22 23:16:44 CET 2002
    copyright            : (C) 2001 by Christophe Guionneau
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

void grVtxTable::draw ()
{
	if (!preDraw()) {
		return;
	}

	if (hasState()) {
		getState()->apply();
	}

#ifdef _SSG_USE_DLIST
	if (dlist)
		glCallList(dlist);
	else
#endif

	if(internalType==TABLE) {
		if (mapLevelBitmap==LEVEL0 || maxTextureUnits==1) {
			ssgVtxTable::draw_geometry ();
		} else if (mapLevelBitmap < 0) {
			draw_geometry_for_a_car();
		} else {
			draw_geometry_multi();
		}
	} else {
		if (mapLevelBitmap==LEVEL0 || maxTextureUnits==1) {
			draw_geometry_array();
		} else if (mapLevelBitmap < 0) {
			draw_geometry_for_a_car_array();
		} else {
			draw_geometry_array ();
		}
	}

	if (postDrawCB != NULL) {
		(*postDrawCB)(this);
	}
}
