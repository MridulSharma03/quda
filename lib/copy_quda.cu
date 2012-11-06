#include <blas_quda.h>
#include <tune_quda.h>
#include <float_vector.h>

// For kernels with precision conversion built in
#define checkSpinorLength(a, b)						\
  {									\
    if (a.Length() != b.Length())					\
      errorQuda("lengths do not match: %d %d", a.Length(), b.Length());	\
    if (a.Stride() != b.Stride())					\
      errorQuda("strides do not match: %d %d", a.Stride(), b.Stride());	\
  }

namespace quda {

  QudaTune getBlasTuning();
  QudaVerbosity getBlasVerbosity();
  cudaStream_t* getBlasStream();
    
  namespace copy {

#include <texture.h>

    static struct {
      int x[QUDA_MAX_DIM];
      int stride;
    } blasConstants;

    template <typename FloatN, int N, typename Output, typename Input>
    __global__ void copyKernel(Output Y, Input X, int length) {
      unsigned int i = blockIdx.x*(blockDim.x) + threadIdx.x;
      unsigned int gridSize = gridDim.x*blockDim.x;

      while (i < length) {
	FloatN x[N];
	X.load(x, i);
	Y.save(x, i);
	i += gridSize;
      }
    }

    template <typename FloatN, int N, typename Output, typename Input>
    class CopyCuda : public Tunable {

    private:
      Input &X;
      Output &Y;
      const int length;

      int sharedBytesPerThread() const { return 0; }
      int sharedBytesPerBlock(const TuneParam &param) const { return 0; }

      virtual bool advanceSharedBytes(TuneParam &param) const
      {
	TuneParam next(param);
	advanceBlockDim(next); // to get next blockDim
	int nthreads = next.block.x * next.block.y * next.block.z;
	param.shared_bytes = sharedBytesPerThread()*nthreads > sharedBytesPerBlock(param) ?
	  sharedBytesPerThread()*nthreads : sharedBytesPerBlock(param);
	return false;
      }

    public:
      CopyCuda(Output &Y, Input &X, int length) : X(X), Y(Y), length(length) { ; }
      virtual ~CopyCuda() { ; }

      TuneKey tuneKey() const {
	std::stringstream vol, aux;
	vol << blasConstants.x[0] << "x";
	vol << blasConstants.x[1] << "x";
	vol << blasConstants.x[2] << "x";
	vol << blasConstants.x[3];
	aux << "stride=" << blasConstants.stride << ",out_prec=" << Y.Precision() << ",in_prec=" << X.Precision();
	return TuneKey(vol.str(), "copyKernel", aux.str());
      }  

      void apply(const cudaStream_t &stream) {
	TuneParam tp = tuneLaunch(*this, getBlasTuning(), getBlasVerbosity());
	copyKernel<FloatN, N><<<tp.grid, tp.block, tp.shared_bytes, stream>>>(Y, X, length);
      }

      void preTune() { ; } // no need to save state for copy kernels
      void postTune() { ; } // no need to restore state for copy kernels

      long long flops() const { return 0; }
      long long bytes() const { 
	const int Ninternal = (sizeof(FloatN)/sizeof(((FloatN*)0)->x))*N;
	size_t bytes = (X.Precision() + Y.Precision())*Ninternal;
	if (X.Precision() == QUDA_HALF_PRECISION) bytes += sizeof(float);
	if (Y.Precision() == QUDA_HALF_PRECISION) bytes += sizeof(float);
	return bytes*length; 
      }
    };

    void copyCuda(cudaColorSpinorField &dst, const cudaColorSpinorField &src) {
      if (&src == &dst) return; // aliasing fields
      if (src.Nspin() != 1 && src.Nspin() != 4) errorQuda("nSpin(%d) not supported\n", src.Nspin());

      if (dst.SiteSubset() == QUDA_FULL_SITE_SUBSET || src.SiteSubset() == QUDA_FULL_SITE_SUBSET) {
	copyCuda(dst.Even(), src.Even());
	copyCuda(dst.Odd(), src.Odd());
	return;
      }

      checkSpinorLength(dst, src);

      for (int d=0; d<QUDA_MAX_DIM; d++) blasConstants.x[d] = src.X()[d];
      blasConstants.stride = src.Stride();

      // For a given dst precision, there are two non-trivial possibilities for the
      // src precision.

      blas_bytes += src.RealLength()*((int)src.Precision() + (int)dst.Precision());

      if (dst.Precision() == src.Precision()) {
	cudaMemcpy(dst.V(), src.V(), dst.Bytes(), cudaMemcpyDeviceToDevice);
	if (dst.Precision() == QUDA_HALF_PRECISION) {
	  cudaMemcpy(dst.Norm(), src.Norm(), dst.NormBytes(), cudaMemcpyDeviceToDevice);
	  blas_bytes += 2*dst.RealLength()*sizeof(float);
	}
      } else if (dst.Precision() == QUDA_DOUBLE_PRECISION && src.Precision() == QUDA_SINGLE_PRECISION) {
	if (src.Nspin() == 4){
	  SpinorTexture<float4, float4, float4, 6, 0> src_tex(src);
	  Spinor<float4, float2, double2, 6> dst_spinor(dst);
	  CopyCuda<float4, 6, Spinor<float4, float2, double2, 6>, 
		   SpinorTexture<float4, float4, float4, 6, 0> >
	    copy(dst_spinor, src_tex, src.Stride());
	  copy.apply(*getBlasStream());	
      } else { //src.Nspin() == 1
	  SpinorTexture<float2, float2, float2, 3, 0> src_tex(src);
	  Spinor<float2, float2, double2, 3> dst_spinor(dst);
	  CopyCuda<float2, 3, Spinor<float2, float2, double2, 3>,
		   SpinorTexture<float2, float2, float2, 3, 0> >
	    copy(dst_spinor, src_tex, src.Stride());
	  copy.apply(*getBlasStream());	
    } 
  } else if (dst.Precision() == QUDA_SINGLE_PRECISION && src.Precision() == QUDA_DOUBLE_PRECISION) {
	if (src.Nspin() == 4){
	  SpinorTexture<float4, float2, double2, 6, 0> src_tex(src);
	  Spinor<float4, float4, float4, 6> dst_spinor(dst);
	  CopyCuda<float4, 6, Spinor<float4, float4, float4, 6>,
		   SpinorTexture<float4, float2, double2, 6, 0> >
	    copy(dst_spinor, src_tex, src.Stride());
	  copy.apply(*getBlasStream());	
      } else { //src.Nspin() ==1
	  SpinorTexture<float2, float2, double2, 3, 0> src_tex(src);
	  Spinor<float2, float2, float2, 3> dst_spinor(dst);
	  CopyCuda<float2, 3, Spinor<float2, float2, float2, 3>,
		   SpinorTexture<float2, float2, double2, 3, 0> >
	  copy(dst_spinor, src_tex, src.Stride());
  copy.apply(*getBlasStream());	
}
  } else if (dst.Precision() == QUDA_SINGLE_PRECISION && src.Precision() == QUDA_HALF_PRECISION) {
	blas_bytes += src.Volume()*sizeof(float);
	if (src.Nspin() == 4){      
	  SpinorTexture<float4, float4, short4, 6, 0> src_tex(src);
	  Spinor<float4, float4, float4, 6> dst_spinor(dst);
	  CopyCuda<float4, 6, Spinor<float4, float4, float4, 6>,
		   SpinorTexture<float4, float4, short4, 6, 0> >
	    copy(dst_spinor, src_tex, src.Stride());
	  copy.apply(*getBlasStream());	
      } else { //nSpin== 1;
	  SpinorTexture<float2, float2, short2, 3, 0> src_tex(src);
	  Spinor<float2, float2, float2, 3> dst_spinor(dst);
	  CopyCuda<float2, 3, Spinor<float2, float2, float2, 3>,
		   SpinorTexture<float2, float2, short2, 3, 0> >
	    copy(dst_spinor, src_tex, src.Stride());
	  copy.apply(*getBlasStream());	
    }
  } else if (dst.Precision() == QUDA_HALF_PRECISION && src.Precision() == QUDA_SINGLE_PRECISION) {
	blas_bytes += dst.Volume()*sizeof(float);
	if (src.Nspin() == 4){
	  SpinorTexture<float4, float4, float4, 6, 0> src_tex(src);
	  Spinor<float4, float4, short4, 6> dst_spinor(dst);
	  CopyCuda<float4, 6, Spinor<float4, float4, short4, 6>,
		   SpinorTexture<float4, float4, float4, 6, 0> >
	    copy(dst_spinor, src_tex, src.Stride());
	  copy.apply(*getBlasStream());	
      } else { //nSpin == 1
	  SpinorTexture<float2, float2, float2, 3, 0> src_tex(src);
	  Spinor<float2, float2, short2, 3> dst_spinor(dst);
	  CopyCuda<float2, 3, Spinor<float2, float2, short2, 3>,
		   SpinorTexture<float2, float2, float2, 3, 0> >
	  copy(dst_spinor, src_tex, src.Stride());
  copy.apply(*getBlasStream());	
}
  } else if (dst.Precision() == QUDA_DOUBLE_PRECISION && src.Precision() == QUDA_HALF_PRECISION) {
	blas_bytes += src.Volume()*sizeof(float);
	if (src.Nspin() == 4){
	  SpinorTexture<double2, float4, short4, 12, 0> src_tex(src);
	  Spinor<double2, double2, double2, 12> dst_spinor(dst);
	  CopyCuda<double2, 12, Spinor<double2, double2, double2, 12>,
		   SpinorTexture<double2, float4, short4, 12, 0> >
	    copy(dst_spinor, src_tex, src.Stride());
	  copy.apply(*getBlasStream());	
      } else { //nSpin == 1
	  SpinorTexture<double2, float2, short2, 3, 0> src_tex(src);
	  Spinor<double2, double2, double2, 3> dst_spinor(dst);
	  CopyCuda<double2, 3, Spinor<double2, double2, double2, 3>,
		   SpinorTexture<double2, float2, short2, 3, 0> >
	    copy(dst_spinor, src_tex, src.Stride());
	  copy.apply(*getBlasStream());	
    }
  } else if (dst.Precision() == QUDA_HALF_PRECISION && src.Precision() == QUDA_DOUBLE_PRECISION) {
	blas_bytes += dst.Volume()*sizeof(float);
	if (src.Nspin() == 4){
	  SpinorTexture<double2, double2, double2, 12, 0> src_tex(src);
	  Spinor<double2, double4, short4, 12> dst_spinor(dst);
	  CopyCuda<double2, 12, Spinor<double2, double4, short4, 12>,
		   SpinorTexture<double2, double2, double2, 12, 0> >
	    copy(dst_spinor, src_tex, src.Stride());
	  copy.apply(*getBlasStream());	
      } else { //nSpin == 1
	  SpinorTexture<double2, double2, double2, 3, 0> src_tex(src);
	  Spinor<double2, double2, short2, 3> dst_spinor(dst);
	  CopyCuda<double2, 3, Spinor<double2, double2, short2, 3>,
		   SpinorTexture<double2, double2, double2, 3, 0> >
	  copy(dst_spinor, src_tex, src.Stride());
	  copy.apply(*getBlasStream());	
	}
      } else {
	errorQuda("Invalid precision combination dst=%d and src=%d", dst.Precision(), src.Precision());
      }
      
      checkCudaError();
    }

  } // namespace copy

  void copyCuda(cudaColorSpinorField &dst, const cudaColorSpinorField &src) {
    copy::copyCuda(dst, src);
  }
  
} // namespace quda