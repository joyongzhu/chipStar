#include <level_zero/ze_api.h>
#include <iostream>
#include <thread>
#include <atomic>

#define CHECK_RESULT(res) if (res != ZE_RESULT_SUCCESS) { std::cerr << "Error: " << res << " at line " << __LINE__ << std::endl; exit(res); }

std::atomic<bool> GpuReady(false);

void monitorGpuReady() {
    while (!GpuReady) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    std::cout << "GPU is now ready." << std::endl;
}

int main() {
    std::cout << "Initializing Level Zero..." << std::endl;
    ze_result_t result = zeInit(0);
    CHECK_RESULT(result);

    std::cout << "Getting driver..." << std::endl;
    uint32_t driverCount = 0;
    result = zeDriverGet(&driverCount, nullptr);
    CHECK_RESULT(result);

    ze_driver_handle_t driver = nullptr;
    result = zeDriverGet(&driverCount, &driver);
    CHECK_RESULT(result);

    std::cout << "Getting device..." << std::endl;
    uint32_t deviceCount = 0;
    result = zeDeviceGet(driver, &deviceCount, nullptr);
    CHECK_RESULT(result);

    ze_device_handle_t device = nullptr;
    result = zeDeviceGet(driver, &deviceCount, &device);
    CHECK_RESULT(result);

    std::cout << "Creating context..." << std::endl;
    ze_context_handle_t context;
    ze_context_desc_t contextDesc = {ZE_STRUCTURE_TYPE_CONTEXT_DESC, nullptr, 0};
    result = zeContextCreate(driver, &contextDesc, &context);
    CHECK_RESULT(result);

    std::cout << "Loading kernel..." << std::endl;
    const char* kernelSource = "simple_kernel.spv";
    size_t kernelSize;
    uint8_t* pKernelBinary;

    FILE* fp = fopen(kernelSource, "rb");
    if (!fp) {
        std::cerr << "Failed to load kernel" << std::endl;
        exit(1);
    }
    fseek(fp, 0, SEEK_END);
    kernelSize = ftell(fp);
    rewind(fp);

    pKernelBinary = new uint8_t[kernelSize];
    if (fread(pKernelBinary, 1, kernelSize, fp) != kernelSize) {
        std::cerr << "Failed to read kernel binary" << std::endl;
        exit(1);
    }
    fclose(fp);

    std::cout << "Creating module..." << std::endl;
    ze_module_handle_t module;
    ze_module_desc_t moduleDesc = {
        ZE_STRUCTURE_TYPE_MODULE_DESC,
        nullptr,
        ZE_MODULE_FORMAT_IL_SPIRV,
        kernelSize,
        pKernelBinary,
        nullptr,
        nullptr
    };
    result = zeModuleCreate(context, device, &moduleDesc, &module, nullptr);
    CHECK_RESULT(result);

    std::cout << "Creating kernel..." << std::endl;
    ze_kernel_handle_t kernel;
    ze_kernel_desc_t kernelDesc = {
        ZE_STRUCTURE_TYPE_KERNEL_DESC,
        nullptr,
        0,
        "simple_kernel"
    };
    result = zeKernelCreate(module, &kernelDesc, &kernel);
    CHECK_RESULT(result);

    std::cout << "Setting up command lists and queues..." << std::endl;
    ze_command_queue_desc_t cmdQueueDesc = {ZE_STRUCTURE_TYPE_COMMAND_QUEUE_DESC, nullptr, 0, 0, ZE_COMMAND_QUEUE_PRIORITY_NORMAL, ZE_COMMAND_QUEUE_MODE_ASYNCHRONOUS};
    ze_command_list_handle_t immCmdList1;
    result = zeCommandListCreateImmediate(context, device, &cmdQueueDesc, &immCmdList1);
    CHECK_RESULT(result);

    ze_command_list_handle_t immCmdList2;
    result = zeCommandListCreateImmediate(context, device, &cmdQueueDesc, &immCmdList2);
    CHECK_RESULT(result);

    ze_command_list_handle_t cmdList;
    ze_command_list_desc_t cmdListDesc = {ZE_STRUCTURE_TYPE_COMMAND_LIST_DESC, nullptr, 0};
    result = zeCommandListCreate(context, device, &cmdListDesc, &cmdList);
    CHECK_RESULT(result);

    ze_command_queue_handle_t cmdQueue;
    result = zeCommandQueueCreate(context, device, &cmdQueueDesc, &cmdQueue);
    CHECK_RESULT(result);

    std::cout << "Setting up synchronization..." << std::endl;
    ze_event_pool_handle_t eventPool;
    ze_event_pool_desc_t eventPoolDesc = {ZE_STRUCTURE_TYPE_EVENT_POOL_DESC, nullptr, 1};
    result = zeEventPoolCreate(context, &eventPoolDesc, 1, &device, &eventPool);
    CHECK_RESULT(result);
    ze_event_handle_t userEvent, kernelEvent1, kernelEvent2;
    ze_event_desc_t eventDesc = {ZE_STRUCTURE_TYPE_EVENT_DESC, nullptr, 0, ZE_EVENT_SCOPE_FLAG_HOST, ZE_EVENT_SCOPE_FLAG_HOST};
    result = zeEventCreate(eventPool, &eventDesc, &userEvent);
    CHECK_RESULT(result);
    eventDesc.index = 1;
    result = zeEventCreate(eventPool, &eventDesc, &kernelEvent1);
    CHECK_RESULT(result);
    eventDesc.index = 2;
    result = zeEventCreate(eventPool, &eventDesc, &kernelEvent2);
    CHECK_RESULT(result);

    std::cout << "Launching kernels..." << std::endl;
    ze_group_count_t launchArgs = {1, 1, 1};
    result = zeCommandListAppendLaunchKernel(immCmdList1, kernel, &launchArgs, kernelEvent1, 0, nullptr);
    CHECK_RESULT(result);
    result = zeCommandListAppendLaunchKernel(immCmdList2, kernel, &launchArgs, kernelEvent2, 0, nullptr);
    CHECK_RESULT(result);

    // Define the waitEvents array with the events you want to wait for
    ze_event_handle_t waitEvents[3] = {userEvent, kernelEvent1, kernelEvent2};

    result = zeCommandListAppendBarrier(cmdList, nullptr, 3, waitEvents);
    CHECK_RESULT(result);

    std::thread monitorThread(monitorGpuReady);
    std::this_thread::sleep_for(std::chrono::seconds(1));


    bool gpuReadyValue = true;
    result = zeCommandListAppendMemoryCopy(cmdList, &GpuReady, &gpuReadyValue, sizeof(GpuReady), nullptr, 0, nullptr);
    CHECK_RESULT(result);

    result = zeCommandListClose(cmdList);
    CHECK_RESULT(result);
    result = zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);
    CHECK_RESULT(result);

    std::cout << "Signaling user event" << std::endl;
    result = zeEventHostSignal(userEvent);
    CHECK_RESULT(result);

    monitorThread.join();

    result = zeCommandListDestroy(immCmdList1);
    CHECK_RESULT(result);
    result = zeCommandListDestroy(immCmdList2);
    CHECK_RESULT(result);
    result = zeCommandListDestroy(cmdList);
    CHECK_RESULT(result);
    result = zeContextDestroy(context);
    CHECK_RESULT(result);

    return 0;
}