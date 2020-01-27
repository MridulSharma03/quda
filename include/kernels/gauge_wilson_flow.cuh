#include <gauge_field_order.h>
#include <index_helper.cuh>
#include <quda_matrix.h>
#include <kernels/gauge_utils.cuh>

namespace quda
{

  enum WFlowStepType {
    WFLOW_STEP_W1,
    WFLOW_STEP_W2,
    WFLOW_STEP_VT,
  };

  template <typename Float_, int nColor_, QudaReconstructType recon_, int wflow_dim_>
  struct GaugeWFlowArg {
    using Float = Float_;
    static constexpr int nColor = nColor_;
    static_assert(nColor == 3, "Only nColor=3 enabled at this time");
    static constexpr QudaReconstructType recon = recon_;
    static constexpr int wflow_dim = wflow_dim_;
    typedef typename gauge_mapper<Float,recon>::type Gauge;

    Gauge out;
    Gauge temp;
    const Gauge in;

    int threads; // number of active threads required
    int_fastdiv X[4];    // grid dimensions
    int border[4];
    int_fastdiv E[4];
    const Float epsilon;
    const Float coeff1x1;
    const Float coeff2x1;
    const QudaWFlowType wflow_type;
    const WFlowStepType step_type;

    GaugeWFlowArg(GaugeField &out, GaugeField &temp, const GaugeField &in, const Float epsilon, const QudaWFlowType wflow_type, const WFlowStepType step_type) :
      out(out),
      in(in),
      temp(temp),
      threads(1),
      coeff1x1(5.0/3.0),
      coeff2x1(-1.0/12.0),
      epsilon(epsilon),
      wflow_type(wflow_type),
      step_type(step_type)
    {
      for (int dir = 0; dir < 4; ++dir) {
        border[dir] = in.R()[dir];
        X[dir] = in.X()[dir] - border[dir] * 2;
        threads *= X[dir];
        E[dir] = in.X()[dir];
      }
      threads /= 2;
    }
  };

  template <QudaWFlowType wflow_type, typename Arg>
  __host__ __device__ inline auto computeStaple(Arg &arg, const int *x, int parity, int dir)
  {
    using real = typename Arg::Float;
    using Link = Matrix<complex<real>, Arg::nColor>;
    Link Stap, Rect, Z;
    // Compute staples and Z factor
    switch (wflow_type) {
    case QUDA_WFLOW_TYPE_WILSON :
      // This function gets stap = S_{mu,nu} i.e., the staple of length 3,
      computeStaple(arg, x, arg.E, parity, dir, Stap, Arg::wflow_dim);
      Z = Stap;
      break;
    case QUDA_WFLOW_TYPE_SYMANZIK :
      // This function gets stap = S_{mu,nu} i.e., the staple of length 3,
      // and the 1x2 and 2x1 rectangles of length 5. From the following paper:
      // https://arxiv.org/abs/0801.1165
      computeStapleRectangle(arg, x, arg.E, parity, dir, Stap, Rect, Arg::wflow_dim);
      Z = (arg.coeff1x1 * Stap + arg.coeff2x1 * Rect);
      break;
    }
    return Z;
  }

  template <QudaWFlowType wflow_type, typename Link, typename Arg>
  __host__ __device__ inline auto computeW1Step(Arg &arg, Link &U, const int *x, const int parity, const int x_cb, const int dir)
  {
    // Compute staples and Z0
    Link Z0 = computeStaple<wflow_type>(arg, x, parity, dir);
    U = arg.in(dir, linkIndex(x, arg.E), parity);
    Z0 *= conj(U);
    arg.temp(dir, x_cb, parity) = Z0;
    Z0 *= (1.0 / 4.0) * arg.epsilon;
    return Z0;
  }

  template <QudaWFlowType wflow_type, typename Link, typename Arg>
  __host__ __device__ inline auto computeW2Step(Arg &arg, Link &U, const int *x, const int parity, const int x_cb, const int dir)
  {
    // Compute staples and Z1
    Link Z1 = (8.0/9.0) * computeStaple<wflow_type>(arg, x, parity, dir);
    U = arg.in(dir, linkIndex(x, arg.E), parity);
    Z1 *= conj(U);

    // Retrieve Z0, (8/9 Z1 - 17/36 Z0) stored in temp
    Link Z0 = arg.temp(dir, x_cb, parity);
    Z0 *= (17.0 / 36.0);
    Z1 = Z1 - Z0;
    arg.temp(dir, x_cb, parity) = Z1;
    Z1 *= arg.epsilon;
    return Z1;
  }

  template <QudaWFlowType wflow_type, typename Link, typename Arg>
  __host__ __device__ inline auto computeVtStep(Arg &arg, Link &U, const int *x, const int parity, const int x_cb, const int dir)
  {
    // Compute staples and Z2
    Link Z2 = (3.0/4.0) * computeStaple<wflow_type>(arg, x, parity, dir);
    U = arg.in(dir, linkIndex(x, arg.E), parity);
    Z2 *= conj(U);

    // Use (8/9 Z1 - 17/36 Z0) computed from W2 step
    Link Z1 = arg.temp(dir, x_cb, parity);
    Z2 = Z2 - Z1;
    Z2 *= arg.epsilon;
    return Z2;
  }

  // Wilson Flow as defined in https://arxiv.org/abs/1006.4518v3
  template <QudaWFlowType wflow_type, WFlowStepType step_type, typename Arg> __global__ void computeWFlowStep(Arg arg)
  {
    using real = typename Arg::Float;
    using Link = Matrix<complex<real>, Arg::nColor>;
    complex<real> im(0.0,-1.0);

    int x_cb = threadIdx.x + blockIdx.x * blockDim.x;
    int parity = threadIdx.y + blockIdx.y * blockDim.y;
    int dir = threadIdx.z + blockIdx.z * blockDim.z;
    if (x_cb >= arg.threads) return;
    if (dir >= Arg::wflow_dim) return;

    //Get stacetime and local coords
    int x[4];
    getCoords(x, x_cb, arg.X, parity);
    for (int dr = 0; dr < 4; ++dr) x[dr] += arg.border[dr];

    Link U, Z;
    switch (step_type) {
    case WFLOW_STEP_W1: Z = computeW1Step<wflow_type>(arg, U, x, parity, x_cb, dir); break;
    case WFLOW_STEP_W2: Z = computeW2Step<wflow_type>(arg, U, x, parity, x_cb, dir); break;
    case WFLOW_STEP_VT: Z = computeVtStep<wflow_type>(arg, U, x, parity, x_cb, dir); break;
    }

    // Compute anti-hermitian projection of Z, exponentiate, update U
    makeAntiHerm(Z);
    Z = im * Z;
    U = exponentiate_iQ(Z) * U;
    arg.out(dir, linkIndex(x, arg.E), parity) = U;
  }

} // namespace quda
