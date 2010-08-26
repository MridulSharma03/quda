#ifndef _DIRAC_QUDA_H
#define _DIRAC_QUDA_H

#include <quda_internal.h>
#include <color_spinor_field.h>
#include <dslash_quda.h>

// Params for Dirac operator
class DiracParam {

 public:
  QudaDiracType type;
  double kappa;
  double mass;
  MatPCType matpcType;
  QudaDagType dagger;
  FullGauge *gauge;
  FullClover *clover;
  FullClover *cloverInv;
  cudaColorSpinorField *tmp1;
  cudaColorSpinorField *tmp2; // used only by Clover operators
  
  FullGauge* fatGauge;  // used by staggered only
  FullGauge* longGauge; // used by staggered only
  
  QudaVerbosity verbose;

  DiracParam() 
   : type(QUDA_INVALID_DIRAC), kappa(0.0), matpcType(QUDA_MATPC_INVALID),
   dagger(QUDA_DAG_INVALID), gauge(0), clover(0), cloverInv(0), tmp1(0),
   tmp2(0), verbose(QUDA_SILENT)
  {

  }

};

void setDiracParam(DiracParam &diracParam, QudaInvertParam *inv_param);
void setDiracSloppyParam(DiracParam &diracParam, QudaInvertParam *inv_param);


// Abstract base class
class Dirac {

 protected:
  FullGauge &gauge;
  double kappa;
  double mass;
  MatPCType matpcType;
  mutable QudaDagType dagger; // mutable to simplify implementation of Mdag
  mutable unsigned long long flops;
  mutable cudaColorSpinorField *tmp1; // temporary hack
  mutable cudaColorSpinorField *tmp2; // temporary hack

 public:
  Dirac(const DiracParam &param);
  Dirac(const Dirac &dirac);
  virtual ~Dirac();
  Dirac& operator=(const Dirac &dirac);

  virtual void checkParitySpinor(const cudaColorSpinorField &, const cudaColorSpinorField &) const;
  virtual void checkFullSpinor(const cudaColorSpinorField &, const cudaColorSpinorField &) const;

  virtual void Dslash(cudaColorSpinorField &out, const cudaColorSpinorField &in, 
		      const QudaParity parity) const = 0;
  virtual void DslashXpay(cudaColorSpinorField &out, const cudaColorSpinorField &in, 
			  const QudaParity parity, const cudaColorSpinorField &x,
			  const double &k) const = 0;
  virtual void M(cudaColorSpinorField &out, const cudaColorSpinorField &in) const = 0;
  virtual void MdagM(cudaColorSpinorField &out, const cudaColorSpinorField &in) const = 0;
  void Mdag(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;

  // required methods to use e-o preconditioning for solving full system
  virtual void prepare(cudaColorSpinorField* &src, cudaColorSpinorField* &sol,
		       cudaColorSpinorField &x, cudaColorSpinorField &b, 
		       const QudaSolutionType) const = 0;
  virtual void reconstruct(cudaColorSpinorField &x, const cudaColorSpinorField &b,
			   const QudaSolutionType) const = 0;

  // Dirac operator factory
  static Dirac* create(const DiracParam &param);

  unsigned long long Flops() const { unsigned long long rtn = flops; flops = 0; return rtn; }
};

// Full Wilson
class DiracWilson : public Dirac {

 protected:

 public:
  DiracWilson(const DiracParam &param);
  DiracWilson(const DiracWilson &dirac);
  virtual ~DiracWilson();
  DiracWilson& operator=(const DiracWilson &dirac);

  virtual void Dslash(cudaColorSpinorField &out, const cudaColorSpinorField &in, 
		      const QudaParity parity) const;
  virtual void DslashXpay(cudaColorSpinorField &out, const cudaColorSpinorField &in, 
			  const QudaParity parity, const cudaColorSpinorField &x, const double &k) const;
  virtual void M(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;
  virtual void MdagM(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;

  virtual void prepare(cudaColorSpinorField* &src, cudaColorSpinorField* &sol,
		       cudaColorSpinorField &x, cudaColorSpinorField &b, 
		       const QudaSolutionType) const;
  virtual void reconstruct(cudaColorSpinorField &x, const cudaColorSpinorField &b,
			   const QudaSolutionType) const;
};

// Even-Odd preconditioned Wilson
class DiracWilsonPC : public DiracWilson {

 private:

 public:
  DiracWilsonPC(const DiracParam &param);
  DiracWilsonPC(const DiracWilsonPC &dirac);
  virtual ~DiracWilsonPC();
  DiracWilsonPC& operator=(const DiracWilsonPC &dirac);

  void M(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;
  void MdagM(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;

  void prepare(cudaColorSpinorField* &src, cudaColorSpinorField* &sol,
	       cudaColorSpinorField &x, cudaColorSpinorField &b, 
	       const QudaSolutionType) const;
  void reconstruct(cudaColorSpinorField &x, const cudaColorSpinorField &b,
		   const QudaSolutionType) const;
};

// Full clover
class DiracClover : public DiracWilson {

 protected:
  FullClover &clover;
  void checkParitySpinor(const cudaColorSpinorField &, const cudaColorSpinorField &, 
			 const FullClover &) const;
  void cloverApply(cudaColorSpinorField &out, const FullClover &clover, const cudaColorSpinorField &in, 
		   const QudaParity parity) const;

 public:
  DiracClover(const DiracParam &param);
  DiracClover(const DiracClover &dirac);
  virtual ~DiracClover();
  DiracClover& operator=(const DiracClover &dirac);

  void Clover(cudaColorSpinorField &out, const cudaColorSpinorField &in, const QudaParity parity) const;
  virtual void M(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;
  virtual void MdagM(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;

  virtual void prepare(cudaColorSpinorField* &src, cudaColorSpinorField* &sol,
		       cudaColorSpinorField &x, cudaColorSpinorField &b, 
		       const QudaSolutionType) const;
  virtual void reconstruct(cudaColorSpinorField &x, const cudaColorSpinorField &b,
			   const QudaSolutionType) const;
};

// Even-Odd preconditioned clover
class DiracCloverPC : public DiracClover {

 private:
  FullClover &cloverInv;

 public:
  DiracCloverPC(const DiracParam &param);
  DiracCloverPC(const DiracCloverPC &dirac);
  virtual ~DiracCloverPC();
  DiracCloverPC& operator=(const DiracCloverPC &dirac);

  void CloverInv(cudaColorSpinorField &out, const cudaColorSpinorField &in, const QudaParity parity) const;
  void Dslash(cudaColorSpinorField &out, const cudaColorSpinorField &in, 
	      const QudaParity parity) const;
  void DslashXpay(cudaColorSpinorField &out, const cudaColorSpinorField &in, 
		  const QudaParity parity, const cudaColorSpinorField &x, const double &k) const;

  void M(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;
  void MdagM(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;

  void prepare(cudaColorSpinorField* &src, cudaColorSpinorField* &sol,
	       cudaColorSpinorField &x, cudaColorSpinorField &b, 
	       const QudaSolutionType) const;
  void reconstruct(cudaColorSpinorField &x, const cudaColorSpinorField &b,
		   const QudaSolutionType) const;
};

// Parity Staggered
class DiracStaggeredPC : public Dirac {

 protected:
  FullGauge* fatGauge;
  FullGauge* longGauge;

 public:
  DiracStaggeredPC(const DiracParam &param);
  DiracStaggeredPC(const DiracStaggeredPC &dirac);
  virtual ~DiracStaggeredPC();
  DiracStaggeredPC& operator=(const DiracStaggeredPC &dirac);

  virtual void checkParitySpinor(const cudaColorSpinorField &, const cudaColorSpinorField &) const;
  
  virtual void Dslash(cudaColorSpinorField &out, const cudaColorSpinorField &in, 
		      const QudaParity parity) const;
  virtual void DslashXpay(cudaColorSpinorField &out, const cudaColorSpinorField &in, 
			  const QudaParity parity, const cudaColorSpinorField &x, const double &k) const;
  virtual void M(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;
  virtual void MdagM(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;

  virtual void prepare(cudaColorSpinorField* &src, cudaColorSpinorField* &sol,
		       cudaColorSpinorField &x, cudaColorSpinorField &b, 
		       const QudaSolutionType) const;
  virtual void reconstruct(cudaColorSpinorField &x, const cudaColorSpinorField &b,
			   const QudaSolutionType) const;
};

// Full Staggered
class DiracStaggered : public Dirac {

 protected:
    FullGauge* fatGauge;
    FullGauge* longGauge;

 public:
  DiracStaggered(const DiracParam &param);
  DiracStaggered(const DiracStaggered &dirac);
  virtual ~DiracStaggered();
  DiracStaggered& operator=(const DiracStaggered &dirac);

  virtual void checkParitySpinor(const cudaColorSpinorField &, const cudaColorSpinorField &) const;
  
  virtual void Dslash(cudaColorSpinorField &out, const cudaColorSpinorField &in, 
		      const QudaParity parity) const;
  virtual void DslashXpay(cudaColorSpinorField &out, const cudaColorSpinorField &in, 
			  const QudaParity parity, const cudaColorSpinorField &x, const double &k) const;
  virtual void M(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;
  virtual void MdagM(cudaColorSpinorField &out, const cudaColorSpinorField &in) const;

  virtual void prepare(cudaColorSpinorField* &src, cudaColorSpinorField* &sol,
		       cudaColorSpinorField &x, cudaColorSpinorField &b, 
		       const QudaSolutionType) const;
  virtual void reconstruct(cudaColorSpinorField &x, const cudaColorSpinorField &b,
			   const QudaSolutionType) const;
};

// Functor base class for applying a given Dirac matrix (M, MdagM, etc.)
class DiracMatrix {

 protected:
  const Dirac *dirac;

 public:
  DiracMatrix(const Dirac &d) : dirac(&d) { }
  DiracMatrix(const Dirac *d) : dirac(d) { }
  virtual ~DiracMatrix() = 0;

  virtual void operator()(cudaColorSpinorField &out, const cudaColorSpinorField &in) const = 0;

  unsigned long long flops() const { return dirac->Flops(); }
};

inline DiracMatrix::~DiracMatrix()
{

}

class DiracM : public DiracMatrix {

 public:
  DiracM(const Dirac &d) : DiracMatrix(d) { }
  DiracM(const Dirac *d) : DiracMatrix(d) { }

  void operator()(cudaColorSpinorField &out, const cudaColorSpinorField &in) const
  {
    dirac->M(out, in);
  }
};

class DiracMdagM : public DiracMatrix {

 public:
  DiracMdagM(const Dirac &d) : DiracMatrix(d) { }
  DiracMdagM(const Dirac *d) : DiracMatrix(d) { }

  void operator()(cudaColorSpinorField &out, const cudaColorSpinorField &in) const
  {
    dirac->MdagM(out, in);
  }
};

class DiracMdag : public DiracMatrix {

 public:
  DiracMdag(const Dirac &d) : DiracMatrix(d) { }
  DiracMdag(const Dirac *d) : DiracMatrix(d) { }

  void operator()(cudaColorSpinorField &out, const cudaColorSpinorField &in) const
  {
    dirac->Mdag(out, in);
  }
};

#endif // _DIRAC_QUDA_H