#include <stddef.h>
#include <pulse/pulseaudio.h>

size_t jukebox_pulse_abi(unsigned field) {
    switch (field) {
    case 0: return sizeof(pa_sample_spec);
    case 1: return sizeof(pa_channel_map);
    case 2: return sizeof(pa_cvolume);
    case 3: return sizeof(pa_client_info);
    case 4: return sizeof(pa_sink_input_info);
    case 5: return offsetof(pa_sink_input_info, client);
    case 6: return offsetof(pa_sink_input_info, volume);
    case 7: return offsetof(pa_sink_input_info, mute);
    case 8: return offsetof(pa_sink_input_info, proplist);
    case 9: return offsetof(pa_sink_input_info, has_volume);
    case 10: return offsetof(pa_sink_input_info, volume_writable);
    case 11: return offsetof(pa_client_info, proplist);
    case 12: return offsetof(pa_cvolume, values);
    default: return (size_t)-1;
    }
}
