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

			throttle = joyInfo->ax[cmd[CMD_THROTTLE].val];
			if (throttle > cmd[CMD_THROTTLE].max) {
				throttle = cmd[CMD_THROTTLE].max;
			} else if (throttle < cmd[CMD_THROTTLE].min) {
				throttle = cmd[CMD_THROTTLE].min;
			}
			car->_accelCmd = fabs(cmd[CMD_THROTTLE].pow *
						pow(fabs((throttle - cmd[CMD_THROTTLE].minVal) /
								(cmd[CMD_THROTTLE].max - cmd[CMD_THROTTLE].min)),
							cmd[CMD_THROTTLE].sens));
