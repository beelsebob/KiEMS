#ifndef DENORMAL_H
#define DENORMAL_H

#if defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64)
#define OPENEMS_ARCH_X86 1
#include <xmmintrin.h>
#else
#define OPENEMS_ARCH_X86 0
#endif

// Disable denormal (subnormal) floating point numbers. These exceedingly
// small numbers may create a substantial overhead depending on the CPU
// (microcode assists are required os x86).
//
// TODO: Only implemented on x86. Do other CPUs like POWER, ARM have
// denormal overheads? If so, implement them too.

namespace Denormal
{
	inline void Disable();
};

inline void Denormal::Disable()
{
#if OPENEMS_ARCH_X86
	// read the old MXCSR setting
	unsigned int oldMXCSR = _mm_getcsr();

	// set DAZ and FZ bits (flush to zero)
	unsigned int newMXCSR = oldMXCSR | 0x8040;

	// write the new MXCSR setting to the MXCSR
	_mm_setcsr( newMXCSR );
#endif
}

#endif // DENORMAL_H
