#include "funset.hpp"
#include <iostream>
#include <memory>
#include <algorithm>
#include <cmath>
#include <cuda_runtime.h> // For the CUDA runtime routines (prefixed with "cuda_")
#include <device_launch_parameters.h>
#include "common.hpp"

/* __global__: 函数类型限定符;在设备上运行;在主机端调用,计算能力3.2及以上可以在
设备端调用;声明的函数的返回值必须是void类型;对此类型函数的调用是异步的,即在
设备完全完成它的运行之前就返回了;对此类型函数的调用必须指定执行配置,即用于在
设备上执行函数时的grid和block的维度,以及相关的流(即插入<<<   >>>运算符);
a kernel,表示此函数为内核函数(运行在GPU上的CUDA并行计算函数称为kernel(内核函
数),内核函数必须通过__global__函数类型限定符定义);*/
__global__ static void layer_prior_vbox(float* dst, int layer_width, int layer_height, int image_width, int image_height,
	float offset, float step, int num_priors, float width, const float* height, const float* variance, int channel_size)
{
	/* gridDim: 内置变量,用于描述线程网格的维度,对于所有线程块来说,这个
	变量是一个常数,用来保存线程格每一维的大小,即每个线程格中线程块的数量.
	一个grid为三维,为dim3类型；
	blockDim: 内置变量,用于说明每个block的维度与尺寸.为dim3类型,包含
	了block在三个维度上的尺寸信息;对于所有线程块来说,这个变量是一个常数,
	保存的是线程块中每一维的线程数量;
	blockIdx: 内置变量,变量中包含的值就是当前执行设备代码的线程块的索引;用
	于说明当前thread所在的block在整个grid中的位置,blockIdx.x取值范围是
	[0,gridDim.x-1],blockIdx.y取值范围是[0, gridDim.y-1].为uint3类型,
	包含了一个block在grid中各个维度上的索引信息;
	threadIdx: 内置变量,变量中包含的值就是当前执行设备代码的线程索引;用于
	说明当前thread在block中的位置;如果线程是一维的可获取threadIdx.x,如果
	是二维的还可获取threadIdx.y,如果是三维的还可获取threadIdx.z;为uint3类
	型,包含了一个thread在block中各个维度的索引信息 */
	int x = threadIdx.x + blockIdx.x * blockDim.x;
	int y = threadIdx.y + blockIdx.y * blockDim.y;

	if (x < layer_width && y < layer_height) {
		float center_x = (x + offset) * step;
		float center_y = (y + offset) * step;
		int idx = x * num_priors * 4 + y * (layer_width * num_priors * 4);

		for (int s = 0; s < num_priors; ++s) {
			float box_width = width;
			float box_height = height[s];
			int idx1 = idx + s * 4;

			dst[idx1] = (center_x - box_width / 2.) / image_width;
			dst[idx1 + 1] = (center_y - box_height / 2.) / image_height;
			dst[idx1 + 2] = (center_x + box_width / 2.) / image_width;
			dst[idx1 + 3] = (center_y + box_height / 2.) / image_height;

			int idx2 = channel_size + idx + s * 4;
			dst[idx2] = variance[0];
			dst[idx2 + 1] = variance[1];
			dst[idx2 + 2] = variance[2];
			dst[idx2 + 3] = variance[3];
		}
	}
}

int layer_prior_vbox_gpu(float* dst, int length, const std::vector<float>& vec1, const std::vector<float>& vec2,
	const std::vector<float>& vec3, float* elapsed_time)
{
	float *dev_dst{ nullptr }, *dev_vec;
	// cudaMalloc: 在设备端分配内存
	cudaMalloc(&dev_dst, length * sizeof(float));
	cudaMalloc(&dev_vec, (vec2.size()+vec3.size()) * sizeof(float));
	/* cudaMemcpy: 在主机端和设备端拷贝数据,此函数第四个参数仅能是下面之一:
	(1). cudaMemcpyHostToHost: 拷贝数据从主机端到主机端
	(2). cudaMemcpyHostToDevice: 拷贝数据从主机端到设备端
	(3). cudaMemcpyDeviceToHost: 拷贝数据从设备端到主机端
	(4). cudaMemcpyDeviceToDevice: 拷贝数据从设备端到设备端
	(5). cudaMemcpyDefault: 从指针值自动推断拷贝数据方向,需要支持
	统一虚拟寻址(CUDA6.0及以上版本)
	cudaMemcpy函数对于主机是同步的 */
	cudaMemcpy(dev_dst, dst, length * sizeof(float), cudaMemcpyHostToDevice);
	cudaMemcpy(dev_vec, vec2.data(), vec2.size() * sizeof(float), cudaMemcpyHostToDevice);
	cudaMemcpy(dev_vec + vec2.size(), vec3.data(), vec3.size() * sizeof(float), cudaMemcpyHostToDevice);

	int layer_width = (int)vec1[0];
	int layer_height = (int)vec1[1];
	int image_width = (int)vec1[2];
	int image_height = (int)vec1[3];
	float offset = vec1[4];
	float step = vec1[5];
	int num_priors = (int)vec1[6];
	float width = vec1[7];
	int channel_size = layer_width * layer_height * num_priors * 4;

	TIME_START_GPU

	/* dim3: 基于uint3定义的内置矢量类型，相当于由3个unsigned int类型组成的
	结构体，可表示一个三维数组，在定义dim3类型变量时，凡是没有赋值的元素都
	会被赋予默认值1 */
	// Note：每一个线程块支持的最大线程数量为1024，即threads.x*threads.y必须小于等于1024
	dim3 threads(32, 32);
	dim3 blocks((layer_width + 31) / 32, (layer_height + 31) / 32);

	/* <<< >>>: 为CUDA引入的运算符,指定线程网格和线程块维度等,传递执行参
	数给CUDA编译器和运行时系统,用于说明内核函数中的线程数量,以及线程是如何
	组织的;尖括号中这些参数并不是传递给设备代码的参数,而是告诉运行时如何
	启动设备代码,传递给设备代码本身的参数是放在圆括号中传递的,就像标准的函
	数调用一样;不同计算能力的设备对线程的总数和组织方式有不同的约束;必须
	先为kernel中用到的数组或变量分配好足够的空间,再调用kernel函数,否则在
	GPU计算时会发生错误,例如越界等 ;
	使用运行时API时,需要在调用的内核函数名与参数列表直接以<<<Dg,Db,Ns,S>>>
	的形式设置执行配置,其中：Dg是一个dim3型变量,用于设置grid的维度和各个
	维度上的尺寸.设置好Dg后,grid中将有Dg.x*Dg.y*Dg.z个block;Db是
	一个dim3型变量,用于设置block的维度和各个维度上的尺寸.设置好Db后,每个
	block中将有Db.x*Db.y*Db.z个thread;Ns是一个size_t型变量,指定各块为此调
	用动态分配的共享存储器大小,这些动态分配的存储器可供声明为外部数组
	(extern __shared__)的其他任何变量使用;Ns是一个可选参数,默认值为0;S为
	cudaStream_t类型,用于设置与内核函数关联的流.S是一个可选参数,默认值0. */
	// Note: 核函数不支持传入参数为vector的data()指针，需要cudaMalloc和cudaMemcpy，因为vector是在主机内存中
	layer_prior_vbox << <blocks, threads>> >(dev_dst, layer_width, layer_height, image_width, image_height,
		offset, step, num_priors, width, dev_vec, dev_vec + vec2.size(), channel_size);

	/* cudaDeviceSynchronize: kernel的启动是异步的, 为了定位它是否出错, 一
	般需要加上cudaDeviceSynchronize函数进行同步; 将会一直处于阻塞状态,直到
	前面所有请求的任务已经被全部执行完毕,如果前面执行的某个任务失败,将会
	返回一个错误；当程序中有多个流,并且流之间在某一点需要通信时,那就必须
	在这一点处加上同步的语句,即cudaDeviceSynchronize；异步启动
	reference: https://stackoverflow.com/questions/11888772/when-to-call-cudadevicesynchronize */
	cudaDeviceSynchronize();

	TIME_END_GPU

	cudaMemcpy(dst, dev_dst, length * sizeof(float), cudaMemcpyDeviceToHost);

	// cudaFree: 释放设备上由cudaMalloc函数分配的内存
	cudaFree(dev_dst);
	cudaFree(dev_vec);

	return 0;
}
