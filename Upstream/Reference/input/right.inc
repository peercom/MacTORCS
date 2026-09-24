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

			ax0 = joyInfo->ax[cmd[CMD_RIGHTSTEER].val] - cmd[CMD_RIGHTSTEER].deadZone;
			if (ax0 > cmd[CMD_RIGHTSTEER].max) {
				ax0 = cmd[CMD_RIGHTSTEER].max;
			} else if (ax0 < cmd[CMD_RIGHTSTEER].min) {
				ax0 = cmd[CMD_RIGHTSTEER].min;
			}
			
			// normalize ax to 0..1
			ax0 = (ax0 - cmd[CMD_RIGHTSTEER].min) / (cmd[CMD_RIGHTSTEER].max - cmd[CMD_RIGHTSTEER].min);
			rightSteer = -SIGN(ax0) * cmd[CMD_RIGHTSTEER].pow * pow(fabs(ax0), cmd[CMD_RIGHTSTEER].sens) / (1.0 + cmd[CMD_RIGHTSTEER].spdSens * car->pub.speed);
