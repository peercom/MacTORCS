/***************************************************************************

    file                 : human.cpp
    created              : Sat Mar 18 23:16:38 CET 2000
    copyright            : (C) 2000-2024 by Eric Espie, Bernhard Wymann
    email                : berniw@bluewin.ch

 ***************************************************************************/

/***************************************************************************
 *                                                                         *
 *   This program is free software; you can redistribute it and/or modify  *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 ***************************************************************************/

			ax0 = joyInfo->ax[cmd[CMD_LEFTSTEER].val] + cmd[CMD_LEFTSTEER].deadZone;
			if (ax0 > cmd[CMD_LEFTSTEER].max) {
				ax0 = cmd[CMD_LEFTSTEER].max;
			} else if (ax0 < cmd[CMD_LEFTSTEER].min) {
				ax0 = cmd[CMD_LEFTSTEER].min;
			}
			
			// normalize ax0 to -1..0
			ax0 = (ax0 - cmd[CMD_LEFTSTEER].max) / (cmd[CMD_LEFTSTEER].max - cmd[CMD_LEFTSTEER].min);
			leftSteer = -SIGN(ax0) * cmd[CMD_LEFTSTEER].pow * pow(fabs(ax0), cmd[CMD_LEFTSTEER].sens) / (1.0 + cmd[CMD_LEFTSTEER].spdSens * car->pub.speed);
