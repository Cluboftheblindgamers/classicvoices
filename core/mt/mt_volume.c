// Adapted from Panthera Speech. See third_party/panthera/LICENSE.
#include "mtengine.h"
#include <string.h>
static const struct { const char *gen, *voice; int norm; } volume_norms[] = {
    {"leopard", "Agnes", 100},
    {"leopard", "Albert", 170},
    {"leopard", "Alex", 180},
    {"leopard", "BadNews", 180},
    {"leopard", "Bahh", 170},
    {"leopard", "Bells", 170},
    {"leopard", "Boing", 170},
    {"leopard", "Bruce", 100},
    {"leopard", "Bubbles", 170},
    {"leopard", "Cellos", 170},
    {"leopard", "Deranged", 170},
    {"leopard", "Fred", 180},
    {"leopard", "GoodNews", 180},
    {"leopard", "Hysterical", 170},
    {"leopard", "Junior", 180},
    {"leopard", "Kathy", 173},
    {"leopard", "Organ", 170},
    {"leopard", "Princess", 170},
    {"leopard", "Ralph", 170},
    {"leopard", "Trinoids", 170},
    {"leopard", "Vicki", 120},
    {"leopard", "Victoria", 100},
    {"leopard", "Whisper", 180},
    {"leopard", "Zarvox", 170},
    {"snowleopard", "Agnes", 100},
    {"snowleopard", "Albert", 170},
    {"snowleopard", "Alex", 146},
    {"snowleopard", "BadNews", 180},
    {"snowleopard", "Bahh", 170},
    {"snowleopard", "Bells", 170},
    {"snowleopard", "Boing", 170},
    {"snowleopard", "Bruce", 100},
    {"snowleopard", "Bubbles", 170},
    {"snowleopard", "Cellos", 170},
    {"snowleopard", "Deranged", 170},
    {"snowleopard", "Fred", 180},
    {"snowleopard", "GoodNews", 180},
    {"snowleopard", "Hysterical", 170},
    {"snowleopard", "Junior", 180},
    {"snowleopard", "Kathy", 173},
    {"snowleopard", "Organ", 170},
    {"snowleopard", "Princess", 170},
    {"snowleopard", "Ralph", 171},
    {"snowleopard", "Trinoids", 170},
    {"snowleopard", "Vicki", 119},
    {"snowleopard", "Victoria", 100},
    {"snowleopard", "Whisper", 180},
    {"snowleopard", "Zarvox", 170},
    {"lion", "Agnes", 100},
    {"lion", "Albert", 170},
    {"lion", "Alex", 119},
    {"lion", "BadNews", 180},
    {"lion", "Bahh", 170},
    {"lion", "Bells", 170},
    {"lion", "Boing", 180},
    {"lion", "Bruce", 100},
    {"lion", "Bubbles", 170},
    {"lion", "Cellos", 175},
    {"lion", "Deranged", 170},
    {"lion", "Fred", 180},
    {"lion", "GoodNews", 169},
    {"lion", "Hysterical", 170},
    {"lion", "Junior", 177},
    {"lion", "Kathy", 172},
    {"lion", "Organ", 167},
    {"lion", "Princess", 165},
    {"lion", "Ralph", 174},
    {"lion", "Trinoids", 170},
    {"lion", "Vicki", 117},
    {"lion", "Victoria", 100},
    {"lion", "Whisper", 180},
    {"lion", "Zarvox", 170},
};
int mte_volume_milli(int level, const char *gen, const char *voice)
{
    unsigned i;
    int norm = 100, divisor = 90, value;
    if (level < 0) level = 0;
    if (level > 100) level = 100;
    if (!gen) gen = "";
    if (!strcmp(gen, "tiger")) divisor = 100;
    for (i = 0; i < sizeof(volume_norms)/sizeof(volume_norms[0]); i++)
        if (!strcmp(gen, volume_norms[i].gen) && !strcmp(voice, volume_norms[i].voice)) {
            norm = volume_norms[i].norm; break;
        }
    value = (norm * level * 10 + divisor/2) / divisor;
    return value > 2000 ? 2000 : value;
}
