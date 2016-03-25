#include <cstdlib>
#include <cstdio>
#include <string>
#include <iostream>

#include <color_spinor_field.h>
#include <clover_field.h>

// these control the Wilson-type actions
#ifdef GPU_WILSON_DIRAC
//#define DIRECT_ACCESS_LINK
//#define DIRECT_ACCESS_WILSON_SPINOR
//#define DIRECT_ACCESS_WILSON_ACCUM
//#define DIRECT_ACCESS_WILSON_INTER
//#define DIRECT_ACCESS_WILSON_PACK_SPINOR
//#define DIRECT_ACCESS_CLOVER
#endif // GPU_WILSON_DIRAC

#include <quda_internal.h>
#include <dslash_quda.h>
#include <sys/time.h>
#include <blas_quda.h>
#include <face_quda.h>

#include <inline_ptx.h>

namespace quda {

  namespace asym_clover {

#undef GPU_STAGGERED_DIRAC
#include <dslash_constants.h>
#include <dslash_textures.h>
#include <dslash_index.cuh>

    // Enable shared memory dslash for Fermi architecture
    //#define SHARED_WILSON_DSLASH
    //#define SHARED_8_BYTE_WORD_SIZE // 8-byte shared memory access

#ifdef GPU_CLOVER_DIRAC
#define DD_CLOVER 2
#include <wilson_dslash_def.h>    // Wilson Dslash kernels (including clover)
#undef DD_CLOVER
#endif

#ifndef DSLASH_SHARED_FLOATS_PER_THREAD
#define DSLASH_SHARED_FLOATS_PER_THREAD 0
#endif

#include <dslash_quda.cuh>

  } // end namespace asym_clover

  // declare the dslash events
#include <dslash_events.cuh>

  using namespace asym_clover;

#ifdef GPU_CLOVER_DIRAC
  template <typename sFloat, typename gFloat, typename cFloat>
  class AsymCloverDslashCuda : public SharedDslashCuda {

  private:
    const gFloat *gauge0, *gauge1;
    const cFloat *clover;
    const float *cloverNorm;
    const double a;

  protected:
    unsigned int sharedBytesPerThread() const
    {
      if (dslashParam.kernel_type == INTERIOR_KERNEL) {
	int reg_size = (typeid(sFloat)==typeid(double2) ? sizeof(double) : sizeof(float));
	return DSLASH_SHARED_FLOATS_PER_THREAD * reg_size;
      } else {
	return 0;
      }
    }

  public:
    AsymCloverDslashCuda(cudaColorSpinorField *out, const gFloat *gauge0, const gFloat *gauge1, 
			 const QudaReconstructType reconstruct, const cFloat *clover, 
			 const float *cloverNorm, int cl_stride, const cudaColorSpinorField *in,
			 const cudaColorSpinorField *x, const double a, const int dagger)
      : SharedDslashCuda(out, in, x, reconstruct, dagger), gauge0(gauge0), gauge1(gauge1), clover(clover),
	cloverNorm(cloverNorm), a(a)
    { 
      bindSpinorTex<sFloat>(in, out, x);
      dslashParam.cl_stride = cl_stride;
      if (!x) errorQuda("Asymmetric clover dslash only defined for Xpay");
    }

    virtual ~AsymCloverDslashCuda() { unbindSpinorTex<sFloat>(in, out, x); }

    void apply(const cudaStream_t &stream)
    {
#ifdef SHARED_WILSON_DSLASH
      if (dslashParam.kernel_type == EXTERIOR_KERNEL_X) 
	errorQuda("Shared dslash does not yet support X-dimension partitioning");
#endif
      TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
      ASYM_DSLASH(asymCloverDslash, tp.grid, tp.block, tp.shared_bytes, stream, dslashParam,
                  (sFloat*)out->V(), (float*)out->Norm(), gauge0, gauge1, clover, cloverNorm, 
                  (sFloat*)in->V(), (float*)in->Norm(), (sFloat*)x, (float*)x->Norm(), a);
    }

    long long flops() const {
      int clover_flops = 504;
      long long flops = DslashCuda::flops();
      switch(dslashParam.kernel_type) {
      case EXTERIOR_KERNEL_X:
      case EXTERIOR_KERNEL_Y:
      case EXTERIOR_KERNEL_Z:
      case EXTERIOR_KERNEL_T:
      case EXTERIOR_KERNEL_ALL:
	break;
      case INTERIOR_KERNEL:
      case KERNEL_POLICY:
	// clover flops are done in the interior kernel
	flops += clover_flops * in->VolumeCB();	  
	break;
      }
      return flops;
    }

    long long bytes() const {
      bool isHalf = in->Precision() == sizeof(short) ? true : false;
      int clover_bytes = 72 * in->Precision() + (isHalf ? 2*sizeof(float) : 0);
      long long bytes = DslashCuda::bytes();
      switch(dslashParam.kernel_type) {
      case EXTERIOR_KERNEL_X:
      case EXTERIOR_KERNEL_Y:
      case EXTERIOR_KERNEL_Z:
      case EXTERIOR_KERNEL_T:
      case EXTERIOR_KERNEL_ALL:
	break;
      case INTERIOR_KERNEL:
      case KERNEL_POLICY:
	bytes += clover_bytes*in->VolumeCB();
	break;
      }

      return bytes;
    }

  };
#endif // GPU_CLOVER_DIRAC

#include <dslash_policy.cuh>

  void asymCloverDslashCuda(cudaColorSpinorField *out, const cudaGaugeField &gauge, const FullClover cloverInv,
			    const cudaColorSpinorField *in, const int parity, const int dagger, 
			    const cudaColorSpinorField *x, const double &a, const int *commOverride,
			    TimeProfile &profile)
  {
    inSpinor = (cudaColorSpinorField*)in; // EVIL

#ifdef GPU_CLOVER_DIRAC
    int Npad = (in->Ncolor()*in->Nspin()*2)/in->FieldOrder(); // SPINOR_HOP in old code
    for(int i=0;i<4;i++){
      dslashParam.ghostDim[i] = commDimPartitioned(i); // determines whether to use regular or ghost indexing at boundary
      dslashParam.ghostOffset[i][0] = in->GhostOffset(i,0)/in->FieldOrder();
      dslashParam.ghostOffset[i][1] = in->GhostOffset(i,1)/in->FieldOrder();
      dslashParam.ghostNormOffset[i][0] = in->GhostNormOffset(i,0);
      dslashParam.ghostNormOffset[i][1] = in->GhostNormOffset(i,1);
      dslashParam.commDim[i] = (!commOverride[i]) ? 0 : commDimPartitioned(i); // switch off comms if override = 0
    }

    void *cloverP, *cloverNormP;
    QudaPrecision clover_prec = bindCloverTex(cloverInv, parity, &cloverP, &cloverNormP);

    void *gauge0, *gauge1;
    bindGaugeTex(gauge, parity, &gauge0, &gauge1);

    if (in->Precision() != gauge.Precision())
      errorQuda("Mixing gauge and spinor precision not supported");

    if (in->Precision() != clover_prec)
      errorQuda("Mixing clover and spinor precision not supported");

    DslashCuda *dslash = 0;
    size_t regSize = sizeof(float);

    if (in->Precision() == QUDA_DOUBLE_PRECISION) {
      dslash = new AsymCloverDslashCuda<double2, double2, double2>
	(out, (double2*)gauge0, (double2*)gauge1, gauge.Reconstruct(), 
	 (double2*)cloverP, (float*)cloverNormP, cloverInv.stride, in, x, a, dagger);
      regSize = sizeof(double);
    } else if (in->Precision() == QUDA_SINGLE_PRECISION) {
      dslash = new AsymCloverDslashCuda<float4, float4, float4>
	(out, (float4*)gauge0, (float4*)gauge1, gauge.Reconstruct(), 
	 (float4*)cloverP, (float*)cloverNormP, cloverInv.stride, in, x, a, dagger);
    } else if (in->Precision() == QUDA_HALF_PRECISION) {
      dslash = new AsymCloverDslashCuda<short4, short4, short4>
	(out, (short4*)gauge0, (short4*)gauge1, gauge.Reconstruct(), 
	 (short4*)cloverP, (float*)cloverNormP, cloverInv.stride, in, x, a, dagger);
    }

#ifndef GPU_COMMS
    DslashPolicyTune dslash_policy(*dslash, const_cast<cudaColorSpinorField*>(in), regSize, parity, dagger, in->Volume(), in->GhostFace(), profile);
    dslash_policy.apply(0);
#else
    DslashPolicyImp* dslashImp = DslashFactory::create(QUDA_GPU_COMMS_DSLASH);
    (*dslashImp)(*dslash, const_cast<cudaColorSpinorField*>(in), regSize, parity, dagger, in->Volume(), in->GhostFace(), profile);
    delete dslashImp;
#endif

    delete dslash;
    unbindGaugeTex(gauge);
    unbindCloverTex(cloverInv);

    checkCudaError();
#else
    errorQuda("Clover dslash has not been built");
#endif

  }

}
