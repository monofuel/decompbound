/* Independent libretro ABI smoke and behavior test; no game assets are used. */
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
#define ROM_SIZE (3u * 1024u * 1024u)
#define HEADER_SIZE 512u
#define PIXEL_FORMAT_COMMAND 10u
#define XRGB8888 1u
#define DEVICE_NONE 0u
#define DEVICE_JOYPAD 1u
#define MEMORY_SAVE_RAM 0u
#define MEMORY_SYSTEM_RAM 2u
#define LOG_INTERFACE_COMMAND 27u
#define ERROR_LOG_LEVEL 3u
#define MAX_RETAINED_RSS_KIB 32768

struct game_info { const char *path; const void *data; size_t size; const char *meta; };
struct system_info { const char *name, *version, *extensions; bool fullpath, block_extract; };
struct geometry { unsigned width, height, max_width, max_height; float aspect; };
struct timing { double fps, sample_rate; };
struct av_info { struct geometry geometry; struct timing timing; };
typedef bool (*environment_cb)(unsigned, void *);
typedef void (*video_cb)(const void *, unsigned, unsigned, size_t);
typedef void (*sample_cb)(int16_t, int16_t);
typedef size_t (*batch_cb)(const int16_t *, size_t);
typedef void (*poll_cb)(void);
typedef int16_t (*input_cb)(unsigned, unsigned, unsigned, unsigned);
struct log_callback { void (*log)(int, const char *, ...); };
struct variable { const char *key, *value; };

struct api {
  void (*set_environment)(environment_cb); void (*set_video_refresh)(video_cb);
  void (*set_audio_sample)(sample_cb); void (*set_audio_sample_batch)(batch_cb);
  void (*set_input_poll)(poll_cb); void (*set_input_state)(input_cb);
  void (*init)(void); void (*deinit)(void); unsigned (*api_version)(void);
  void (*get_system_info)(struct system_info *); void (*get_system_av_info)(struct av_info *);
  void (*set_controller_port_device)(unsigned, unsigned); void (*reset)(void); void (*run)(void);
  size_t (*serialize_size)(void); bool (*serialize)(void *, size_t); bool (*unserialize)(const void *, size_t);
  void (*cheat_reset)(void); void (*cheat_set)(unsigned, bool, const char *);
  bool (*load_game)(const struct game_info *);
  bool (*load_game_special)(unsigned, const struct game_info *, size_t);
  void (*unload_game)(void); unsigned (*get_region)(void);
  void *(*get_memory_data)(unsigned); size_t (*get_memory_size)(unsigned);
};
#define LOAD(a, handle, field) do { void *symbol = dlsym((handle), "retro_" #field); CHECK(symbol); memcpy(&(a).field, &symbol, sizeof(symbol)); } while (0)
static struct api open_api(void *handle) {
  struct api a;
  LOAD(a,handle,set_environment); LOAD(a,handle,set_video_refresh); LOAD(a,handle,set_audio_sample);
  LOAD(a,handle,set_audio_sample_batch); LOAD(a,handle,set_input_poll); LOAD(a,handle,set_input_state);
  LOAD(a,handle,init); LOAD(a,handle,deinit); LOAD(a,handle,api_version); LOAD(a,handle,get_system_info);
  LOAD(a,handle,get_system_av_info); LOAD(a,handle,set_controller_port_device); LOAD(a,handle,reset);
  LOAD(a,handle,run); LOAD(a,handle,serialize_size); LOAD(a,handle,serialize); LOAD(a,handle,unserialize);
  LOAD(a,handle,cheat_reset); LOAD(a,handle,cheat_set); LOAD(a,handle,load_game);
  LOAD(a,handle,load_game_special); LOAD(a,handle,unload_game); LOAD(a,handle,get_region);
  LOAD(a,handle,get_memory_data); LOAD(a,handle,get_memory_size);
  return a;
}
static bool accept_pixels = true;
static bool dual_screen = false;
static unsigned pixel_requests, polls, videos, frames, samples, buttons;
static uint32_t pixel;
static uint32_t first_card, second_card;
static unsigned errors;
static char last_error[256];
static void core_log(int level, const char *format, ...) {
  CHECK(level == ERROR_LOG_LEVEL);
  va_list arguments;
  va_start(arguments, format);
  vsnprintf(last_error, sizeof(last_error), format, arguments);
  va_end(arguments);
  errors++;
}
static bool environment(unsigned command, void *data) {
  if (command == PIXEL_FORMAT_COMMAND) { CHECK(data); CHECK(*(unsigned *)data == XRGB8888); pixel_requests++; return accept_pixels; }
  if (command == LOG_INTERFACE_COMMAND) { CHECK(data); ((struct log_callback *)data)->log = core_log; return true; }
  if (command == 16) {
    struct variable *v = data; CHECK(v && !strcmp(v[0].key, "decompbound_dual_screen"));
    CHECK(strstr(v[0].value, "disabled|enabled") && !v[1].key); return true;
  }
  if (command == 15) {
    struct variable *v = data; CHECK(v && !strcmp(v->key, "decompbound_dual_screen"));
    v->value = dual_screen ? "enabled" : "disabled"; return true;
  }
  return false;
}
static void video(const void *data, unsigned width, unsigned height, size_t pitch) {
  CHECK(data); CHECK(width == 256 && height == (dual_screen ? 448u : 224u) && pitch == 1024);
  pixel = ((const uint32_t *)data)[0]; videos++;
  if (dual_screen) {
    first_card = ((const uint32_t *)data)[(224 + 144) * 256 + 72];
    second_card = ((const uint32_t *)data)[(224 + 144) * 256 + 128];
  }
}
static void sample(int16_t left, int16_t right) { (void)left; (void)right; samples++; }
static size_t batch(const int16_t *data, size_t count) { CHECK(data); frames += (unsigned)count; return count; }
static void poll(void) { polls++; }
static int16_t input(unsigned port, unsigned device, unsigned index, unsigned id) {
  CHECK(device == DEVICE_JOYPAD || (dual_screen && device == 6)); CHECK(index == 0);
  return device == DEVICE_JOYPAD && port == 0 && id < 14 && (buttons & (1u << id)) != 0;
}
static void callbacks(struct api a) {
  a.set_environment(environment); a.set_video_refresh(video); a.set_audio_sample(sample);
  a.set_audio_sample_batch(batch); a.set_input_poll(poll); a.set_input_state(input);
}
static void ui_word(unsigned char *r, unsigned offset, unsigned value) {
  r[offset] = (unsigned char)value;
  r[offset + 1] = (unsigned char)(value >> 8);
}
static void ui_rle(unsigned char *r, unsigned offset, unsigned remaining) {
  /* Authored flat two-bit tiles, using long RLE commands rather than game data. */
  while (remaining) {
    unsigned count = remaining < 1024 ? remaining : 1024;
    r[offset++] = (unsigned char)(0xe4u | ((count - 1) >> 8));
    r[offset++] = (unsigned char)(count - 1);
    r[offset++] = 0xff;
    remaining -= count;
  }
  r[offset] = 0xff;
}
static void make_ui(unsigned char *r) {
  /* Independent synthetic descriptors and blank fonts for dual-screen ABI tests. */
  for (unsigned id = 0; id < 5; ++id) {
    unsigned entry = 0x3f054 + id * 12, height = id == 3 ? 8 : 16;
    ui_word(r, entry, 0x8000); r[entry + 2] = 0xc4;
    ui_word(r, entry + 4, 0x8100); r[entry + 6] = 0xc4;
    ui_word(r, entry + 8, height); ui_word(r, entry + 10, height);
    ui_word(r, 0x201fb9 + id * 3, id * 64);
    r[0x201fb9 + id * 3 + 2] = id == 0 ? 1 : 8;
  }
  memset(r + 0x48000, 6, 96); memset(r + 0x48100, 0xff, 96 * 16);
  ui_rle(r, 0x200000, 0x1a00); ui_rle(r, 0x200754, 0x70);
}
static unsigned char *make_rom(size_t prefix) {
  unsigned char *rom = calloc(1, ROM_SIZE + prefix); CHECK(rom);
  unsigned char *r = rom + prefix;
  /* Authored 65816 code: enable display, set red backdrop, repeatedly copy
     auto-joy registers into mirrored WRAM. The reset vector enters $008000. */
  const unsigned char code[] = {
    0xa9,0x00,0x8d,0x21,0x21, /* LDA #0; STA $2121 */
    0xa9,0x1f,0x8d,0x22,0x21, /* LDA #31; STA $2122 */
    0xa9,0x00,0x8d,0x22,0x21, /* LDA #0; STA $2122 */
    0xa9,0x03,0x8d,0x21,0x21, /* Set synthetic UI color 3 to red too. */
    0xa9,0x1f,0x8d,0x22,0x21,
    0xa9,0x00,0x8d,0x22,0x21,
    0xa9,0x0f,0x8d,0x02,0x00, /* LDA #15; STA $0002 */
    0xad,0x02,0x00,0x8d,0x00,0x21, /* LDA $0002; STA $2100 */
    0xad,0x18,0x42,0x8d,0x00,0x00, /* LDA $4218; STA $0000 */
    0xad,0x19,0x42,0x8d,0x01,0x00, /* LDA $4219; STA $0001 */
    0xee,0x03,0x00, /* INC $0003, a timing witness. */
    0x4c,0x23,0x80 /* JMP $8023 */
  };
  memcpy(r + 0x8000, code, sizeof(code));
  memcpy(r + 0xffc0, "SYNTHETIC ABI TEST   ", 21);
  r[0xffd5] = 0x21; r[0xfffc] = 0x00; r[0xfffd] = 0x80;
  make_ui(r);
  return rom;
}
static void check_metadata(struct api a) {
  struct system_info s = {0}; struct av_info av = {0};
  CHECK(a.api_version() == 1); a.get_system_info(&s); a.get_system_av_info(&av);
  CHECK(s.name && s.name[0] && s.version && s.version[0]);
  CHECK(s.extensions && strcmp(s.extensions, "smc|sfc") == 0 && !s.fullpath && !s.block_extract);
  CHECK(av.geometry.width == 256 && av.geometry.height == 224);
  CHECK(av.geometry.max_width == 256 && av.geometry.max_height == 224);
  CHECK(av.geometry.aspect == (float)(8.0 / 7.0));
  CHECK(av.timing.fps == 60.0 && av.timing.sample_rate == 31980.0);
  CHECK(a.get_region() == 0); CHECK(a.serialize_size() == 0);
  char state = 0; CHECK(!a.serialize(&state, 1)); CHECK(!a.unserialize(&state, 1));
  CHECK(!a.load_game_special(0, NULL, 0)); a.cheat_reset(); a.cheat_set(0, true, "invalid");
}
static void run_frame(struct api a, unsigned expected_audio) {
  unsigned old_polls = polls, old_videos = videos, old_frames = frames, old_samples = samples;
  a.run(); CHECK(polls > old_polls && videos == old_videos + 1);
  CHECK(frames - old_frames == expected_audio && samples == old_samples);
}
static void check_loaded(struct api a) {
  uint8_t *ram = a.get_memory_data(MEMORY_SYSTEM_RAM), *sram = a.get_memory_data(MEMORY_SAVE_RAM);
  CHECK(ram && sram); CHECK(a.get_memory_size(MEMORY_SYSTEM_RAM) == 131072);
  CHECK(a.get_memory_size(MEMORY_SAVE_RAM) == 8192);
  a.set_controller_port_device(0, DEVICE_JOYPAD);
  for (unsigned i = 0; i < 12; ++i) {
    buttons = 1u << i; run_frame(a, 533);
    CHECK((unsigned)(ram[0] | ((unsigned)ram[1] << 8)) == (1u << (15u - i)));
  }
  CHECK((pixel & 0x00ffffffu) == 0x00ff0000u);
  ram[2] = 0x80; run_frame(a, 533); run_frame(a, 533); CHECK((pixel & 0x00ffffffu) == 0);
  ram[2] = 0x0f; run_frame(a, 533); CHECK((pixel & 0x00ffffffu) == 0x00ff0000u);
  CHECK(a.get_memory_data(MEMORY_SYSTEM_RAM) == ram && a.get_memory_data(MEMORY_SAVE_RAM) == sram);
  sram[0] = 0x5a; sram[8191] = 0xa5; a.reset();
  CHECK(a.get_memory_data(MEMORY_SAVE_RAM) == sram && sram[0] == 0x5a && sram[8191] == 0xa5);
  a.set_controller_port_device(0, DEVICE_NONE); buttons = 0xfff; run_frame(a, 533);
  CHECK(ram[0] == 0 && ram[1] == 0);
  a.set_controller_port_device(0, DEVICE_JOYPAD);
  buttons = 1; a.reset(); ram[3] = 0; run_frame(a, 533);
  uint8_t timing = ram[3]; CHECK(timing != 0 && ram[1] == 0x80);
  a.reset(); ram[3] = 0; a.set_audio_sample_batch(NULL);
  unsigned old_samples = samples, old_frames = frames;
  a.run(); CHECK(samples - old_samples == 533 && frames == old_frames);
  CHECK(ram[1] == 0x80 && ram[3] == timing);
  a.reset(); ram[3] = 0; a.set_audio_sample(NULL);
  old_samples = samples; old_frames = frames; a.run();
  CHECK(samples == old_samples && frames == old_frames);
  CHECK(ram[1] == 0x80 && ram[3] == timing);
  a.set_audio_sample(sample); a.set_audio_sample_batch(batch);
}
static void check_companion(struct api a) {
  uint8_t *ram = a.get_memory_data(MEMORY_SYSTEM_RAM);
  const unsigned base = 0x99ce, stride = 0x5f;
  ram[0x986f] = 1; ram[0x9870] = 2; ram[0x98a4] = 2;
  ram[base] = 'A' + 0x30; ram[base + 5] = 1;
  ram[base + stride] = 'B' + 0x30; ram[base + stride + 5] = 1;
  buttons = 0; run_frame(a, 533);
  CHECK(first_card == 0xff0000 && second_card == 0);
  buttons = 1u << 13; run_frame(a, 533);
  CHECK(first_card == 0 && second_card == 0xff0000);
  CHECK(ram[0] == 0 && ram[1] == 0);
  run_frame(a, 533); CHECK(second_card == 0xff0000);
  a.reset(); buttons = 0; run_frame(a, 533);
  CHECK(first_card == 0xff0000);
}
int main(int argc, char **argv) {
  CHECK(argc == 2);
  long initial_peak = 0;
  for (unsigned cycle = 0; cycle < 22; ++cycle) {
    dual_screen = (cycle % 2) != 0;
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL); CHECK(handle);
    struct api a = open_api(handle); callbacks(a); a.init(); check_metadata(a);
    unsigned previous_errors = errors;
    CHECK(!a.load_game(NULL)); CHECK(errors == previous_errors + 1 && strstr(last_error, "3 MiB"));
    struct game_info invalid = {0}; CHECK(!a.load_game(&invalid));
    uint8_t short_rom[4] = {0}; invalid.data = short_rom; invalid.size = sizeof(short_rom); CHECK(!a.load_game(&invalid));
    unsigned char *rom = make_rom(cycle == 1 ? HEADER_SIZE : 0);
    struct game_info game = {NULL, rom, ROM_SIZE + (cycle == 1 ? HEADER_SIZE : 0), NULL};
    if (cycle == 0) {
      accept_pixels = false; CHECK(!a.load_game(&game));
      CHECK(strstr(last_error, "XRGB8888")); accept_pixels = true;
    }
    unsigned old_requests = pixel_requests; CHECK(a.load_game(&game)); CHECK(pixel_requests > old_requests);
    struct av_info loaded_av; a.get_system_av_info(&loaded_av);
    CHECK(loaded_av.geometry.height == (dual_screen ? 448u : 224u));
    memset(rom, 0, game.size); free(rom);
    if (cycle < 2) check_loaded(a); else { a.reset(); run_frame(a, 533); }
    if (dual_screen) check_companion(a);
    if (cycle == 0) {
      uint8_t saved[8192]; memcpy(saved, a.get_memory_data(MEMORY_SAVE_RAM), sizeof(saved));
      a.unload_game(); rom = make_rom(0); game.data = rom; game.size = ROM_SIZE;
      CHECK(a.load_game(&game)); free(rom);
      uint8_t *sram = a.get_memory_data(MEMORY_SAVE_RAM); CHECK(sram);
      memcpy(sram, saved, sizeof(saved)); a.reset();
      CHECK(sram[0] == 0x5a && sram[8191] == 0xa5);
    }
    a.unload_game();
    CHECK(a.get_memory_data(MEMORY_SAVE_RAM) == NULL && a.get_memory_size(MEMORY_SAVE_RAM) == 0);
    CHECK(a.get_memory_data(1) == NULL && a.get_memory_size(1) == 0);
    a.deinit(); callbacks(a); a.init(); rom = make_rom(0); game.data = rom; game.size = ROM_SIZE;
    CHECK(a.load_game(&game)); free(rom); buttons = 1; run_frame(a, 533);
    CHECK(((uint8_t *)a.get_memory_data(MEMORY_SYSTEM_RAM))[1] == 0x80);
    a.set_controller_port_device(0, DEVICE_NONE);
    a.unload_game(); a.deinit(); CHECK(dlclose(handle) == 0);
    struct rusage usage; CHECK(getrusage(RUSAGE_SELF, &usage) == 0);
    if (cycle == 1) initial_peak = usage.ru_maxrss;
    if (cycle == 21) {
      printf("libretro lifecycle peak RSS: %ld -> %ld KiB\n", initial_peak, usage.ru_maxrss);
      CHECK(usage.ru_maxrss - initial_peak < MAX_RETAINED_RSS_KIB);
    }
  }
  puts("libretro C host: passed"); return 0;
}
