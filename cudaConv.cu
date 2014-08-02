#include <cuda.h>
#include <cufft.h>
#include "cutil.h"
#include "mex.h"
#include "gpu/mxGPUArray.h"

#define IMUL(a, b) __mul24(a, b)
static bool debug = true;

/*
 * Device Code
 */

////////////////////////////////////////////////////////////////////////////////
// Pad data with zeros, 
////////////////////////////////////////////////////////////////////////////////
__global__ void padData(
    float *d_PaddedData,
    float *d_Data,
    int fftW,
    int fftH,
    int dataW,
    int dataH,
    int FEATURE_DIM
){
    const int x = IMUL(blockDim.x, blockIdx.x) + threadIdx.x;
    const int y = IMUL(blockDim.y, blockIdx.y) + threadIdx.y;
    const int z = IMUL(blockDim.z, blockIdx.z) + threadIdx.z;

    if(x < fftW && y < fftH && z < FEATURE_DIM){
        if(x < dataW && y < dataH)
            d_PaddedData[IMUL(z, IMUL(fftW, fftH)) + IMUL(x, fftH) + y] = 
                    d_Data[ IMUL(z, IMUL(dataH, dataW)) + IMUL(x, dataH ) + y];
        else
            d_PaddedData[IMUL(z, IMUL(fftW, fftH)) + IMUL(x, fftH) + y] = 0;
    }
}

////////////////////////////////////////////////////////////////////////////////
// Modulate Fourier image of padded data by Fourier image of padded kernel
// and normalize by FFT size
////////////////////////////////////////////////////////////////////////////////
__device__ void complexMulAndScale(cufftComplex& a, cufftComplex b, float c){
    const cufftComplex t = {c * (a.x * b.x - a.y * b.y), c * (a.y * b.x + a.x * b.y)};
    a = t;
}

__device__ void complexConjMulAndScale(cufftComplex& a, cufftComplex b, float c){
    const cufftComplex t = {c * (a.x * b.x + a.y * b.y), c * (a.y * b.x - a.x * b.y)};
    a = t;
}

__global__ void elementwiseProductAndNormalize(
    cufftComplex *fft_PaddedData,
    cufftComplex *fft_PaddedKernel,
    int FFT_H,
    int FFT_W,
    int FEATURE_DIM,
    float scale
){
    const int x = IMUL(blockDim.x, blockIdx.x) + threadIdx.x;
    const int y = IMUL(blockDim.y, blockIdx.y) + threadIdx.y;
    const int z = IMUL(blockDim.z, blockIdx.z) + threadIdx.z;

    if(x < FFT_W && y < FFT_H && z < FEATURE_DIM){
        const int i = IMUL(z, IMUL(FFT_W, FFT_H)) + IMUL(FFT_H, x) + y;
        complexConjMulAndScale(fft_PaddedData[i], fft_PaddedKernel[i], scale);
    }
}

/* Support in-place computation, i.e. input and output can be the same */
__global__ void sumAlongFeatures(
    float *convolutionResult,
    float *convolutionPerFeature,
    int FFT_H,
    int FFT_W,
    int FEATURE_DIM
){
    const int x = IMUL(blockDim.x, blockIdx.x) + threadIdx.x;
    const int y = IMUL(blockDim.y, blockIdx.y) + threadIdx.y;

    if(x < FFT_W && y < FFT_H){
        const int result_i = IMUL(FFT_H, x) + y;
        const int N = IMUL(FFT_W, FFT_H);

        convolutionResult[result_i] = convolutionPerFeature[result_i];
        for (int z = 1; z < FEATURE_DIM; z++){
            convolutionResult[result_i] += 
                convolutionPerFeature[IMUL(z, N) + result_i];
        }
    }
}

/*
 * Host code
 */

////////////////////////////////////////////////////////////////////////////////
// Helper functions
////////////////////////////////////////////////////////////////////////////////
//Round a / b to nearest higher integer value
int iDivUp(int a, int b){
    return (a % b != 0) ? (a / b + 1) : (a / b);
}

//Align a to nearest higher multiple of b
int iAlignUp(int a, int b){
    return (a % b != 0) ?  (a - a % b + b) : a;
}

////////////////////////////////////////////////////////////////////////////////
// Data configuration
////////////////////////////////////////////////////////////////////////////////
int computeFFTsize(int dataSize){
    //Highest non-zero bit position of dataSize
    int hiBit;
    //Neares lower and higher powers of two numbers for dataSize
    unsigned int lowPOT, hiPOT;

    //Align data size to a multiple of half-warp
    //in order to have each line starting at properly aligned addresses
    //for coalesced global memory writes in padKernel() and padData()
    dataSize = iAlignUp(dataSize, 16);

    //Find highest non-zero bit
    for(hiBit = 31; hiBit >= 0; hiBit--)
        if(dataSize & (1U << hiBit)) break;

    //No need to align, if already power of two
    lowPOT = 1U << hiBit;
    if(lowPOT == dataSize) return dataSize;

    //Align to a nearest higher power of two, if the size is small enough,
    //else align only to a nearest higher multiple of 512,
    //in order to save computation and memory bandwidth
    hiPOT = 1U << (hiBit + 1);
    //if(hiPOT <= 1024)
        return hiPOT;
    //else 
    //  return iAlignUp(dataSize, 512);
}


////////////////////////////////////////////////////////////////////////////////
// Mex Entry
////////////////////////////////////////////////////////////////////////////////
void mexFunction(int nlhs, mxArray *plhs[],
                 int nrhs, mxArray const *prhs[])
{
    /* Declare all variables.*/
    const mxGPUArray *mxFFTData;
    const mxGPUArray *mxKernel;
    mxGPUArray *mxFFTKernel;
    mxGPUArray *mxConvolution;
    float2 *d_CFFT_DATA;
    float2 *d_CFFT_KERNEL;
    float *d_CONVOLUTION;

    float *h_Kernel;
    float *d_Kernel;
    char const * const errId = "parallel:gpu:mexGPUExample:InvalidInput";
    char const * const errMsg = "Invalid input to MEX file.";

    /* Choose a reasonably sized number of threads for the block. */
    int const THREAD_PER_BLOCK_H = 16;
    int const THREAD_PER_BLOCK_W = 8;
    int const THREAD_PER_BLOCK_D = 8;
    int const THREAD_PER_BLOCK_2D = 32;

    const mwSize * mxKernel_Dim;
    const mwSize * mxFFT_Dim;
    // int MblocksPerGrid, NblocksPerGrid;
    int KERNEL_H, KERNEL_W, DATA_H, DATA_W, 
        PADDING_H, PADDING_W, FFT_H, FFT_W, FEATURE_DIM,
        DATA_SIZE, KERNEL_SIZE, FFT_SIZE, CFFT_SIZE;

    
    /* Initialize the MathWorks GPU API. */
    mxInitGPU();

    
    /* Throw an error if the input is not a GPU array. */
    if ((nrhs!=2) ||
            !mxIsGPUArray(prhs[0]) || 
            mxGetNumberOfDimensions(prhs[1]) != 3 || 
            mxGetClassID(prhs[1]) != mxSINGLE_CLASS) {
        mexErrMsgIdAndTxt(errId, errMsg);
    }

    mxFFTData = mxGPUCreateFromMxArray(prhs[0]);
    mxFFT_Dim = mxGPUGetDimensions(mxFFTData);

    // Get Kernel Data
    if (!mxIsGPUArray(prhs[1])){
        h_Kernel = (float *)mxGetData(prhs[1]);
        mxKernel_Dim = mxGetDimensions(prhs[1]);
        cudaMalloc((void **)&d_Kernel, KERNEL_SIZE);
        cudaMemcpy(d_Kernel, h_Kernel, KERNEL_SIZE, cudaMemcpyHostToDevice);
        mxKernel = NULL;
    }else{
        mxKernel = mxGPUCreateFromMxArray(prhs[1]);
        mxKernel_Dim = mxGPUGetDimensions(mxKernel);
        d_Kernel = (float *)mxGPUGetDataReadOnly(mxKernel);
    }

    // FFT Dim

    FFT_H = mxFFT_Dim[0];
    FFT_W = mxFFT_Dim[1];
    FEATURE_DIM = mxFFT_Dim[2];
    if(debug) fprintf(stderr,"FFT Data size: h=%d, w=%d, f=%d\n", FFT_H, FFT_W, FEATURE_DIM);

    // Kernel dimensions
    KERNEL_H = mxKernel_Dim[0];
    KERNEL_W = mxKernel_Dim[1];

    if(debug) fprintf(stderr,"Kernel size: h=%d, w=%d\n", KERNEL_H, KERNEL_W);

    if (FEATURE_DIM != mxKernel_Dim[2] || KERNEL_W > FFT_W || KERNEL_H > FFT_H ){
        mexErrMsgIdAndTxt(errId, errMsg);
    }

    KERNEL_SIZE = KERNEL_W * KERNEL_H * FEATURE_DIM * sizeof(float);
    FFT_SIZE  = FFT_W  * FFT_H  * FEATURE_DIM * sizeof(float);
    CFFT_SIZE = FFT_W  * FFT_H  * FEATURE_DIM * sizeof(float2);

    // Get Complex FFT data handle
    d_CFFT_DATA = (float2 *)mxGPUGetDataReadOnly(mxFFTData);

    /*  Pad Kernel */
    /* Create a GPUArray to hold the result and get its underlying pointer. */
    /* TODO : replace it with simple cuda variable after debugging */
    mxFFTKernel = mxGPUCreateGPUArray(3,
                            mxFFT_Dim,
                            mxSINGLE_CLASS,
                            mxCOMPLEX,
                            MX_GPU_DO_NOT_INITIALIZE);

    // mxConvolution = mxGPUCreateGPUArray(2,
    //                         mxFFT_Dim, // Third element will not be accessed
    //                         mxSINGLE_CLASS,
    //                         mxREAL,
    //                         MX_GPU_DO_NOT_INITIALIZE);

    d_CFFT_KERNEL = (cufftComplex *)(mxGPUGetData(mxFFTKernel));
    // d_CONVOLUTION = (cufftReal *)(mxGPUGetData(mxConvolution));

    dim3 threadBlock3D(THREAD_PER_BLOCK_H, THREAD_PER_BLOCK_W, THREAD_PER_BLOCK_D);
    dim3 dataBlockGrid3D( iDivUp(FFT_W, threadBlock3D.x), 
                        iDivUp(FFT_H, threadBlock3D.y), 
                        iDivUp(FEATURE_DIM, threadBlock3D.z));

    dim3 threadBlock2D( THREAD_PER_BLOCK_2D, THREAD_PER_BLOCK_2D);
    dim3 dataBlockGrid2D( iDivUp(FFT_W, threadBlock2D.x), 
                        iDivUp(FFT_H, threadBlock2D.y));

    padData<<<dataBlockGrid3D, threadBlock3D>>>(
        (cufftReal *)d_CFFT_KERNEL,
        d_Kernel,
        FFT_W,
        FFT_H,
        KERNEL_W,
        KERNEL_H,
        FEATURE_DIM
        );

    int BATCH = 2;
    int FFT_Dims[] = { FFT_W, FFT_H /2 + 1 };
    int CFFT_Dims[] = { FFT_W, FFT_H / 2 + 1 }; // ????
    // int CFFT_Dims[] = { FFT_W, FFT_H }; // ????
    int dist = FFT_H * FFT_W;
    
    cufftHandle FFTplan_R2C, FFTplan_C2R;
    CUFFT_SAFE_CALL(cufftPlanMany(&FFTplan_R2C, 
        2, // rank
        FFT_Dims, 
        FFT_Dims, 1, dist, // *inembed, istride, idist
        FFT_Dims, 1, dist, // *onembed, ostride, odist
        CUFFT_R2C, 
        BATCH)); // batch

    if(debug) fprintf(stderr,"Plan R2C done\n");

    CUFFT_SAFE_CALL(cufftPlanMany(&FFTplan_C2R, 
        2, // rank
        FFT_Dims,
        CFFT_Dims, 1, dist, // *inembed, istride, idist
        FFT_Dims, 1, dist, // *onembed, ostride, odist
        CUFFT_C2R, 
        BATCH)); // batch

    if(debug) fprintf(stderr,"Plan C2R done\n");

    CUFFT_SAFE_CALL(cufftExecR2C(FFTplan_R2C, (cufftReal *)d_CFFT_KERNEL, d_CFFT_KERNEL));
    CUFFT_SAFE_CALL(cudaDeviceSynchronize());

    if(debug) fprintf(stderr,"FFT done\n");

    // {
    // /* Element-wise multiplication in frequency domain */
    // elementwiseProductAndNormalize<<<dataBlockGrid3D, threadBlock3D>>>(
    //         d_CFFT_KERNEL,
    //         d_CFFT_DATA,
    //         FFT_H,
    //         FFT_W,
    //         FEATURE_DIM,
    //         1.0f / (FFT_W * FFT_H)
    //     );

    // CUDA_SAFE_CALL(cufftExecC2R(FFTplan_C2R, (cufftComplex *)d_CFFT_KERNEL, (cufftReal *)d_CFFT_KERNEL));
    // CUDA_SAFE_CALL(cudaDeviceSynchronize());




    // sumAlongFeatures<<<dataBlockGrid2D, threadBlock2D>>>(
    //         (float *)d_CONVOLUTION,
    //         (float *)d_CFFT_KERNEL,
    //         FFT_H,
    //         FFT_W,
    //         FEATURE_DIM
    //     );

    // }

    plhs[0] = mxGPUCreateMxArrayOnGPU(mxFFTKernel);
    // plhs[1] = mxGPUCreateMxArrayOnGPU(mxConvolution);
    /*
     * The mxGPUArray pointers are host-side structures that refer to device
     * data. These must be destroyed before leaving the MEX function.
     */
    mxGPUDestroyGPUArray(mxFFTKernel);
    // mxGPUDestroyGPUArray(mxConvolution);
    cufftDestroy(FFTplan_R2C);
}