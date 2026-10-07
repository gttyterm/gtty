// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

#include "gtty_beep.h"

#ifdef __APPLE__
#include <AudioToolbox/AudioToolbox.h>

int gtty_beep(void) {
    AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);
    return 1;
}
#else
int gtty_beep(void) {
    return 0; /* no standard system beep on Linux desktops: gtty plays a tone */
}
#endif
