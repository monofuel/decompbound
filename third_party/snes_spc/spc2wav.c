/* spc2wav: render .spc to WAV using blargg snes_spc reference.
   Usage: spc2wav <in.spc> <out.wav> <seconds> [--no-filter]
   Default: apply SPC_Filter (like play_spc.c) for authentic.
   --no-filter: raw DSP output (for honest our-DSP vs ref-DSP diff).
   Renders exactly seconds*32000 stereo samples (interleaved s16 @32kHz).
   Reuses demo/wave_writer.c + demo_util.c.
*/

#include "snes_spc/spc.h"
#include "demo/wave_writer.h"
#include "demo/demo_util.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

int main( int argc, char** argv )
{
	if ( argc < 4 ) {
		printf( "Usage: spc2wav <in.spc> <out.wav> <seconds> [--no-filter]\n" );
		return 1;
	}
	const char* in_spc = argv[1];
	const char* out_wav = argv[2];
	double seconds = atof( argv[3] );
	int apply_filter = 1;
	if ( argc >= 5 && strcmp( argv[4], "--no-filter" ) == 0 ) {
		apply_filter = 0;
	}

	/* Create emulator and optional filter */
	SNES_SPC* snes_spc = spc_new();
	SPC_Filter* filter = NULL;
	if ( apply_filter ) {
		filter = spc_filter_new();
	}
	if ( !snes_spc || (apply_filter && !filter) ) error( "Out of memory" );

	/* Load SPC */
	{
		long spc_size;
		void* spc = load_file( in_spc, &spc_size );
		error( spc_load_spc( snes_spc, spc, spc_size ) );
		free( spc );
		spc_clear_echo( snes_spc );
		if ( apply_filter ) {
			spc_filter_clear( filter );
		}
	}

	long rate = spc_sample_rate;
	long total_samples = (long)( seconds * rate * 2.0 ); /* stereo interleaved count */
	if ( total_samples < 2 ) total_samples = 2;
	/* ensure even */
	if ( total_samples & 1 ) total_samples++;

	wave_open( rate, out_wav );
	wave_enable_stereo();

	long written = 0;
	enum { BUF_SIZE = 2048 };
	while ( written < total_samples ) {
		short buf[ BUF_SIZE ];
		long remain = total_samples - written;
		long n = (remain > BUF_SIZE) ? BUF_SIZE : remain;
		/* n must be even for stereo pairs, but spc_play accepts count of samples */
		if ( n & 1 ) n--; /* make even */
		if ( n <= 0 ) break;
		error( spc_play( snes_spc, (int)n, buf ) );
		if ( apply_filter ) {
			spc_filter_run( filter, buf, (int)n );
		}
		wave_write( buf, n );
		written += n;
	}

	if ( apply_filter ) spc_filter_delete( filter );
	spc_delete( snes_spc );
	wave_close();

	return 0;
}
