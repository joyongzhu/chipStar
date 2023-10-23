#!/bin/bash

set -e
# Check if at least one argument is provided
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <debug|release> <llvm-15|llvm-16|llvm-17> [--skip-build] [--num-tries=1] [--num-threads=1]"
  exit 1
fi

# Check if the first argument is either "debug" or "release"
if [ "$1" != "debug" ] && [ "$1" != "release" ]; then
  echo "Error: Invalid argument. Must be either 'debug' or 'release'."
  exit 1
fi

# Set the build type based on the argument
build_type=$(echo "$1" | tr '[:lower:]' '[:upper:]')

if [ "$2" == "llvm-15" ]; then
  LLVM=llvm-15
  CLANG=clang/clang15-spirv-omp
elif [ "$2" == "llvm-16" ]; then
  LLVM=llvm-16
  CLANG=clang/clang16-spirv-omp
elif [ "$2" == "llvm-17" ]; then
  LLVM=llvm-17
  CLANG=clang/clang17-spirv-omp
else
  echo "$2"
  echo "Invalid 2nd argument. Use either 'llvm-15', 'llvm-16' or 'llvm-17'."
  exit 1
fi

shift
shift

# Set the number of tries based on the argument or default to 1
num_tries=1
num_threads=""
timeout=200
for arg in "$@"
do
  case $arg in
    --num-threads=*)
      num_threads="${arg#*=}"
      shift
      ;;
    --num-threads)
      shift
      num_threads="$1"
      shift
      ;;
    --num-tries=*)
      num_tries="${arg#*=}"
      shift
      ;;
    --num-tries)
      shift
      num_tries="$1"
      shift
      ;;
    --skip-build)
      skip_build=true
      shift
      ;;
    --timeout=*)
      timeout="${arg#*=}"
      shift
      ;;
    --timeout)
      shift
      timeout="$1"
      shift
      ;;
    *)
      ;;
  esac
done


# Use default -j option or override if num_threads is set
function ctest_j_option {
  local default_j=$1
  if [ ! -z "$num_threads" ]; then
    echo "-j $num_threads"
  else
    echo "-j $default_j"
  fi
}


# Print out the arguments
echo "build_type  = ${build_type}"
echo "LLVM        = ${LLVM}"
echo "CLANG       = ${CLANG}"
echo "num_tries   = ${num_tries}"
echo "num_threads = ${num_threads}"
echo "skip_build  = ${skip_build}"
echo "timeout     = ${timeout}"

# source /opt/intel/oneapi/setvars.sh intel64 &> /dev/null
source /etc/profile.d/modules.sh &> /dev/null
export MODULEPATH=$MODULEPATH:/home/pvelesko/modulefiles:/opt/intel/oneapi/modulefiles:/opt/modulefiles
export IGC_EnableDPEmulation=1
export OverrideDefaultFP64Settings=1
export CHIP_LOGLEVEL=err
export POCL_KERNEL_CACHE=0
export CHIP_L0_COLLECT_EVENTS_TIMEOUT=30

# Use OpenCL for building/test discovery to prevent Level Zero from being used in multi-thread/multi-process environment
module load $CLANG
module load intel/compute-runtime intel/opencl

output=$(clinfo -l 2>&1 | grep "Platform #0")
echo $output
if [ $? -ne 0 ]; then
    echo "clinfo failed to execute."
    exit 1
fi

# check if the output is empty
if [ -z "$output" ]; then
    echo "No OpenCL devices detected."
    exit 1
fi

if [ $skip_build ]; then
  echo "Skipping build step"
  cd build
else
  # Build the project
  echo "Building project..."
  rm -rf HIPCC
  rm -rf HIP
  rm -rf bitcode/ROCm-Device-Libs
  rm -rf hip-tests
  rm -rf hip-testsuite

  git submodule update --init
  rm -rf build
  rm -rf *_result.txt
  mkdir build
  cd build

  echo "building with $CLANG"
  cmake ../ -DCMAKE_BUILD_TYPE="$build_type" &> /dev/null
  make all build_tests install -j 24 #&> /dev/null
  echo "chipStar build complete." 

  # # Build libCEED
  # export CHIPSTAR_INSTALL_DIR=`pwd`/install # set CHIPSTAR_INSTALL_DIR to current build dir
  # export LIBCEED_DIR=`pwd`/libCEED
  # ../scripts/compile_libceed.sh ${CHIPSTAR_INSTALL_DIR}
fi

# module load HIP/hipBLAS/main/release # for libCEED NOTE: Must be after build step otherwise it will cause link issues.
# # Test PoCL CPU
# echo "begin cpu_pocl_failed_tests"
# module load opencl/pocl
# module list
# ctest --schedule-random --timeout 600 --repeat until-fail:${num_tries} $(ctest_j_option 12) --output-on-failure -E "`cat ./test_lists/cpu_pocl_failed_tests.txt`" | tee cpu_pocl_make_check_result.txt
# module unload opencl/pocl
# echo "end cpu_pocl_failed_tests"

# Test Level Zero Regular Cmd Lists iGPU
echo "begin igpu_level0_failed_reg_tests"
module load level-zero/igpu
module list
CHIP_L0_IMM_CMD_LISTS=OFF ctest --schedule-random --timeout $timeout --repeat until-fail:${num_tries} $(ctest_j_option 4) --output-on-failure -E "`cat ./test_lists/igpu_level0_failed_reg_tests.txt`" | tee igpu_level0_reg_make_check_result.txt
# pushd ${LIBCEED_DIR}
# make FC= CC=clang CXX=clang++ BACKENDS="/gpu/hip/ref /gpu/hip/shared /gpu/hip/gen" prove --repeat until-fail:${num_tries} $(ctest_j_option 12) PROVE_OPS="-j" | tee dgpu_level0_reg_make_check_result.txt
# popd
module unload level-zero/igpu
echo "end igpu_level0_failed_reg_tests"

# # ICL broken for iGPU
# # Test Level Zero Immediate Cmd Lists iGPU
# echo "begin igpu_level0_failed_imm_tests"
# module load level-zero/igpu
# module list
# CHIP_L0_IMM_CMD_LISTS=ON ctest --schedule-random --timeout $timeout --repeat until-fail:${num_tries} $(ctest_j_option 12) --output-on-failure -E "`cat ./test_lists/igpu_level0_failed_imm_tests.txt`" | tee igpu_level0_imm_make_check_result.txt
# # pushd ${LIBCEED_DIR}
# # make FC= CC=clang CXX=clang++ BACKENDS="/gpu/hip/ref /gpu/hip/shared /gpu/hip/gen" prove --repeat until-fail:${num_tries} $(ctest_j_option 12) PROVE_OPS="-j" | tee dgpu_level0_imm_make_check_result.txt
# # popd
# module unload level-zero/igpu
# echo "end igpu_level0_failed_imm_tests"

# Test Level Zero Regular Cmd Lists dGPU
echo "begin dgpu_level0_failed_reg_tests"
module load level-zero/dgpu
module list
CHIP_L0_IMM_CMD_LISTS=OFF ctest --schedule-random --timeout $timeout --repeat until-fail:${num_tries} $(ctest_j_option 4) --output-on-failure -E "`cat ./test_lists/dgpu_level0_failed_reg_tests.txt`" | tee dgpu_level0_reg_make_check_result.txt
# pushd ${LIBCEED_DIR}
# HIP_DIR=${CHIPSTAR_INSTALL_DIR} make FC= CC=clang CXX=clang++ BACKENDS="/gpu/hip/ref /gpu/hip/shared /gpu/hip/gen" prove --repeat until-fail:${num_tries} $(ctest_j_option 12) PROVE_OPS="-j" | tee dgpu_level0_reg_make_check_result.txt
# popd
module unload level-zero/dgpu
echo "end dgpu_level0_failed_reg_tests"

# Test Level Zero Regular Cmd Lists dGPU
echo "begin dgpu_level0_failed_imm_tests"
module load level-zero/dgpu
module list
CHIP_L0_IMM_CMD_LISTS=ON ctest --schedule-random --timeout $timeout --repeat until-fail:${num_tries} $(ctest_j_option 8) --output-on-failure -E "`cat ./test_lists/dgpu_level0_failed_imm_tests.txt`" | tee dgpu_level0_imm_make_check_result.txt
# pushd ${LIBCEED_DIR}
# HIP_DIR=${CHIPSTAR_INSTALL_DIR} make FC= CC=clang CXX=clang++ BACKENDS="/gpu/hip/ref /gpu/hip/shared /gpu/hip/gen" prove --repeat until-fail:${num_tries} $(ctest_j_option 12) PROVE_OPS="-j" | tee dgpu_level0_imm_make_check_result.txt
# popd
module unload level-zero/dgpu
echo "end dgpu_level0_failed_imm_tests"

# Test OpenCL iGPU
echo "begin igpu_opencl_failed_tests"
module load opencl/igpu
module list
ctest --schedule-random --timeout $timeout --repeat until-fail:${num_tries} $(ctest_j_option 4) --output-on-failure -E "`cat ./test_lists/igpu_opencl_failed_tests.txt`" | tee igpu_opencl_make_check_result.txt
#pushd ${LIBCEED_DIR}
#make FC= CC=clang CXX=clang++ BACKENDS="/gpu/hip/ref /gpu/hip/shared /gpu/hip/gen" prove --repeat until-fail:${num_tries} $(ctest_j_option 12) PROVE_OPS="-j" | tee igpu_opencl_make_check_result.txt
#popd
module unload opencl/igpu
echo "end igpu_opencl_failed_tests"

# Test OpenCL dGPU
echo "begin dgpu_opencl_failed_tests"
module load intel/opencl # sets ICD
module load opencl/dgpu # sets CHIP_BE
module list
ctest --schedule-random --timeout $timeout --repeat until-fail:${num_tries} $(ctest_j_option 8) --output-on-failure -E "`cat ./test_lists/dgpu_opencl_failed_tests.txt`" | tee dgpu_opencl_make_check_result.txt
# pushd ${LIBCEED_DIR}
# HIP_DIR=${CHIPSTAR_INSTALL_DIR} make FC= CC=clang CXX=clang++ BACKENDS="/gpu/hip/ref /gpu/hip/shared /gpu/hip/gen" prove --repeat until-fail:${num_tries} $(ctest_j_option 12) PROVE_OPS="-j" | tee dgpu_opencl_make_check_result.txt
# popd
module unload opencl/dgpu intel/opencl
echo "end dgpu_opencl_failed_tests"

# Test OpenCL CPU
# echo "begin cpu_opencl_failed_tests"
# module load opencl/cpu
# module list
# ctest --schedule-random --timeout $timeout --repeat until-fail:${num_tries} $(ctest_j_option 12) --output-on-failure -E "`cat ./test_lists/cpu_opencl_failed_tests.txt`" | tee cpu_opencl_make_check_result.txt
# module unload opencl/cpu
# echo "end cpu_opencl_failed_tests"

function check_tests {
  file="$1"
  if grep -q " 0 tests failed out of" "$file"; then
    echo "PASS"
    return 0
  else
    echo "FAIL"
    grep -E "The following tests FAILED:" -A 1000 "$file" | sed '/^$/q' | tail -n +2
    return 1
  fi
}

function check_libceed {
  file="$1"
  if grep -q "Result: PASS" "$file"; then
    echo "PASS"
    return 0
  else
    echo "FAIL"
    awk '/Test Summary Report/,EOF' "$file"
    return 1
  fi
}

overall_status=0
set +e
echo "RESULTS:"
# ICL broken for iGP
                  #  igpu_level0_imm_make_check_result.txt 
for test_result in dgpu_opencl_make_check_result.txt \
                   igpu_opencl_make_check_result.txt \
                   igpu_level0_reg_make_check_result.txt \
                   dgpu_level0_reg_make_check_result.txt \
                   dgpu_level0_imm_make_check_result.txt
do
  echo -n "${test_result}: "
  check_tests "${test_result}"
  test_status=$?
  if [ $test_status -eq 1 ]; then
    overall_status=1
  fi
done

# # dgpu_opencl_make_check_result
# # libCEED/cpu_pocl_make_check_result.txt https://github.com/CHIP-SPV/H4I-MKLShim/issues/15
# for test_result in libCEED/dgpu_opencl_make_check_result.txt \
#                    libCEED/dgpu_level0_reg_make_check_result.txt \
#                    libCEED/dgpu_level0_imm_make_check_result.txt
                   
# do
#   echo -n "${test_result}: "
#   check_libceed "${test_result}"
#   test_status=$?
#   if [ $test_status -eq 1 ]; then
#     overall_status=1
#   fi
# done

if [ $overall_status -eq 0 ]; then
  exit 0
else
  exit 1
fi
