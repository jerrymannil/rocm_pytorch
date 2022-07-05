#!/bin/bash

ver() {
  printf "%3d%03d%03d%03d" $(echo "$1" | tr '.' ' ');
}

set -ex

install_magma() {
    # "install" hipMAGMA into /opt/rocm/magma by copying after build
    if [[ $(ver $ROCM_VERSION) -ge $(ver 6.0) ]]; then
      git clone https://bitbucket.org/mpruthvi1/magma.git -b pyt1_10_rocm6.x
      pushd magma
    else
      git clone https://bitbucket.org/icl/magma.git -b magma_ctrl_launch_bounds
      pushd magma
      # The branch "magma_ctrl_launch_bounds" is having a fix over the below commit, so keeping the below comment for reference.
      #git checkout 878b1ce02e9cfe4a829be22c8f911e9c0b6bd88f
    fi

    # Work around non-asii characters in certain magma sources; remove this after upstream magma fixes this.
    perl -i.bak -pe 's/[^[:ascii:]]//g' sparse/control/magma_zfree.cpp
    perl -i.bak -pe 's/[^[:ascii:]]//g' sparse/control/magma_zsolverinfo.cpp

    cp make.inc-examples/make.inc.hip-gcc-mkl make.inc
    echo 'LIBDIR += -L$(MKLROOT)/lib' >> make.inc
    echo 'LIB += -Wl,--enable-new-dtags -Wl,--rpath,/opt/rocm/lib -Wl,--rpath,$(MKLROOT)/lib -Wl,--rpath,/opt/rocm/magma/lib' >> make.inc
    echo 'DEVCCFLAGS += --gpu-max-threads-per-block=256' >> make.inc
    export PATH="${PATH}:/opt/rocm/bin"
    if [[ -n "$PYTORCH_ROCM_ARCH" ]]; then
      amdgpu_targets=`echo $PYTORCH_ROCM_ARCH | sed 's/;/ /g'`
    else
      amdgpu_targets=`rocm_agent_enumerator | grep -v gfx000 | sort -u | xargs`
    fi
    for arch in $amdgpu_targets; do
      echo "DEVCCFLAGS += --amdgpu-target=$arch" >> make.inc
    done
    # hipcc with openmp flag may cause isnan() on __device__ not to be found; depending on context, compiler may attempt to match with host definition
    sed -i 's/^FOPENMP/#FOPENMP/g' make.inc
    export PATH="${PATH}:/opt/rocm/bin"
    make -f make.gen.hipMAGMA -j $(nproc)
    make lib/libmagma.so -j $(nproc) MKLROOT=/opt/conda
    make testing/testing_dgemm -j $(nproc) MKLROOT=/opt/conda
    popd
    mv magma /opt/rocm
}

ver() {
    printf "%3d%03d%03d%03d" $(echo "$1" | tr '.' ' ');
}

# Map ROCm version to AMDGPU version
declare -A AMDGPU_VERSIONS=( ["4.5.2"]="21.40.2" ["5.0"]="21.50" ["5.0.1"]="21.50.1" ["5.1"]="22.10" ["5.1.1"]="22.10.1" ["5.1.3"]="22.10.3" ["5.2"]="22.20" ["5.2.3"]="22.20.3" )

install_ubuntu() {
    apt-get update
    if [[ $UBUNTU_VERSION == 18.04 ]]; then
      # gpg-agent is not available by default on 18.04
      apt-get install -y --no-install-recommends gpg-agent
    fi
    if [[ $UBUNTU_VERSION == 20.04 ]]; then
      # gpg-agent is not available by default on 20.04
      apt-get install -y --no-install-recommends gpg-agent
    fi
    apt-get install -y kmod
    apt-get install -y wget

    # Need the libc++1 and libc++abi1 libraries to allow torch._C to load at runtime
    apt-get install -y libc++1
    apt-get install -y libc++abi1

    if [[ $(ver $ROCM_VERSION) -ge $(ver 4.5) ]]; then
        # Add amdgpu repository
        UBUNTU_VERSION_NAME=`cat /etc/os-release | grep UBUNTU_CODENAME | awk -F= '{print $2}'`
        local amdgpu_baseurl
        if [[ $(ver $ROCM_VERSION) -ge $(ver 5.3) ]]; then
          amdgpu_baseurl="https://repo.radeon.com/amdgpu/${ROCM_VERSION}/ubuntu"
        else
          amdgpu_baseurl="https://repo.radeon.com/amdgpu/${AMDGPU_VERSIONS[$ROCM_VERSION]}/ubuntu"
        fi
        echo "deb [arch=amd64] ${amdgpu_baseurl} ${UBUNTU_VERSION_NAME} main" > /etc/apt/sources.list.d/amdgpu.list
    fi

    ROCM_REPO="ubuntu"
    if [[ $(ver $ROCM_VERSION) -lt $(ver 4.2) ]]; then
        ROCM_REPO="xenial"
    fi

    if [[ $(ver $ROCM_VERSION) -ge $(ver 5.3) ]]; then
        ROCM_REPO="${UBUNTU_VERSION_NAME}"
    fi

    # Add rocm repository
    wget -qO - http://repo.radeon.com/rocm/rocm.gpg.key | apt-key add -
    local rocm_baseurl="http://repo.radeon.com/rocm/apt/${ROCM_VERSION}"
    echo "deb [arch=amd64] ${rocm_baseurl} ${ROCM_REPO} main" > /etc/apt/sources.list.d/rocm.list
    apt-get update --allow-insecure-repositories

    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated \
                   rocm-dev \
                   rocm-utils \
                   rocm-libs \
                   rccl \
                   rocprofiler-dev \
                   roctracer-dev

    # precompiled miopen kernels added in ROCm 3.5; search for all unversioned packages
    # if search fails it will abort this script; use true to avoid case where search fails
    MIOPENKERNELS=$(apt-cache search --names-only miopenkernels | awk '{print $1}' | grep -F -v . || true)
    if [[ "x${MIOPENKERNELS}" = x ]]; then
      echo "miopenkernels package not available"
    else
      DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated ${MIOPENKERNELS}
    fi

    if [[ $(ver $ROCM_VERSION) -ge $(ver 5.4) ]]; then
        MIOPENHIPGFX=$(apt-cache search --names-only miopen-hip-gfx | awk '{print $1}' | grep -F -v . || true)
        if [[ "x${MIOPENHIPGFX}" = x ]]; then
          echo "miopen-hip-gfx package not available"
        else
          DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated ${MIOPENHIPGFX}
        fi
    fi

    install_magma

    # Cleanup
    apt-get autoclean && apt-get clean
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
}

install_centos() {

  yum update -y
  yum install -y kmod
  yum install -y wget
  
  if [[ $OS_VERSION == 9 ]]; then 
      dnf install -y openblas-serial
      dnf install -y dkms kernel-headers kernel-devel
  else
      yum install -y openblas-devel
      yum install -y dkms kernel-headers-`uname -r` kernel-devel-`uname -r`
  fi

  yum install -y epel-release

  if [[ $(ver $ROCM_VERSION) -ge $(ver 4.5) ]]; then
      # Add amdgpu repository
      local amdgpu_baseurl
      if [[ $OS_VERSION == 9 ]]; then
          amdgpu_baseurl="https://repo.radeon.com/amdgpu/${AMDGPU_VERSIONS[$ROCM_VERSION]}/rhel/9.0/main/x86_64"
      else
        if [[ $(ver $ROCM_VERSION) -ge $(ver 5.3) ]]; then
          amdgpu_baseurl="https://repo.radeon.com/amdgpu/${ROCM_VERSION}/rhel/7.9/main/x86_64"
        else
          amdgpu_baseurl="https://repo.radeon.com/amdgpu/${AMDGPU_VERSIONS[$ROCM_VERSION]}/rhel/7.9/main/x86_64"
        fi
      fi
      echo "[AMDGPU]" > /etc/yum.repos.d/amdgpu.repo
      echo "name=AMDGPU" >> /etc/yum.repos.d/amdgpu.repo
      echo "baseurl=${amdgpu_baseurl}" >> /etc/yum.repos.d/amdgpu.repo
      echo "enabled=1" >> /etc/yum.repos.d/amdgpu.repo
      echo "gpgcheck=1" >> /etc/yum.repos.d/amdgpu.repo
      echo "gpgkey=http://repo.radeon.com/rocm/rocm.gpg.key" >> /etc/yum.repos.d/amdgpu.repo
  fi

  if [[ $OS_VERSION == 9 ]]; then
      local rocm_baseurl="invalid-url"
  else
      local rocm_baseurl="http://repo.radeon.com/rocm/yum/${ROCM_VERSION}/main"
  fi
  echo "[ROCm]" > /etc/yum.repos.d/rocm.repo
  echo "name=ROCm" >> /etc/yum.repos.d/rocm.repo
  echo "baseurl=${rocm_baseurl}" >> /etc/yum.repos.d/rocm.repo
  echo "enabled=1" >> /etc/yum.repos.d/rocm.repo
  echo "gpgcheck=1" >> /etc/yum.repos.d/rocm.repo
  echo "gpgkey=http://repo.radeon.com/rocm/rocm.gpg.key" >> /etc/yum.repos.d/rocm.repo

  if [[ $OS_VERSION == 9 ]]; then
      yum update -y --nogpgcheck
      dnf --enablerepo=crb install -y perl-File-BaseDir
      yum install -y --nogpgcheck rocm-ml-sdk rocm-developer-tools
  else
      yum update -y
      yum install -y \
                   rocm-dev \
                   rocm-utils \
                   rocm-libs \
                   rccl \
                   rocprofiler-dev \
                   roctracer-dev
  fi

  # if search fails it will abort this script; use true to avoid case where search fails
  MIOPENKERNELS=$(yum -q search miopenkernels | grep miopenkernels- | awk '{print $1}'| grep -F kdb. || true)
  if [[ "x${MIOPENKERNELS}" = x ]]; then
    echo "miopenkernels package not available"
  else
    yum install -y ${MIOPENKERNELS}
  fi

  if [[ $(ver $ROCM_VERSION) -ge $(ver 5.4) ]]; then
      MIOPENHIPGFX=$(yum -q search miopen-hip-gfx | grep miopen-hip-gfx | awk '{print $1}'| grep -F kdb. || true)
      if [[ "x${MIOPENHIPGFX}" = x ]]; then
        echo "miopen-hip-gfx package not available"
      else
        yum install -y ${MIOPENHIPGFX}
      fi
  fi

  install_magma

  # Cleanup
  yum clean all
  rm -rf /var/cache/yum
  rm -rf /var/lib/yum/yumdb
  rm -rf /var/lib/yum/history
}

OS_VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"')

# Install Python packages depending on the base OS
ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
case "$ID" in
  ubuntu)
    install_ubuntu
    ;;
  centos)
    install_centos
    ;;
  *)
    echo "Unable to determine OS..."
    exit 1
    ;;
esac