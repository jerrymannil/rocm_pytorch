#!/bin/bash

set -ex

install_ubuntu() {
  # NVIDIA dockers for RC releases use tag names like `11.0-cudnn8-devel-ubuntu18.04-rc`,
  # for this case we will set UBUNTU_VERSION to `18.04-rc` so that the Dockerfile could
  # find the correct image. As a result, here we have to check for
  #   "$UBUNTU_VERSION" == "18.04"*
  # instead of
  #   "$UBUNTU_VERSION" == "18.04"
  if [[ "$UBUNTU_VERSION" == "18.04"* ]]; then
    cmake3="cmake=3.10*"
    maybe_libiomp_dev="libiomp-dev"
  elif [[ "$UBUNTU_VERSION" == "20.04"* ]]; then
    cmake3="cmake=3.16*"
    maybe_libiomp_dev=""
  else
    cmake3="cmake=3.5*"
    maybe_libiomp_dev="libiomp-dev"
  fi

  # Install common dependencies
  apt-get update
  # TODO: Some of these may not be necessary
  ccache_deps="asciidoc docbook-xml docbook-xsl xsltproc"
  numpy_deps="gfortran"
  apt-get install -y --no-install-recommends \
    $ccache_deps \
    $numpy_deps \
    ${cmake3} \
    apt-transport-https \
    autoconf \
    automake \
    build-essential \
    ca-certificates \
    curl \
    git \
    libatlas-base-dev \
    libc6-dbg \
    ${maybe_libiomp_dev} \
    libyaml-dev \
    libz-dev \
    libjpeg-dev \
    libasound2-dev \
    libsndfile-dev \
    software-properties-common \
    sudo \
    wget \
    vim

  # Cleanup package manager
  apt-get autoclean && apt-get clean
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
}

install_centos() {
  # Need EPEL for many packages we depend on.
  # See http://fedoraproject.org/wiki/EPEL
  # extras repo is not there for CentOS 9 and epel-release is already part of repo list
  if [[ $OS_VERSION == 9 ]]; then
      yum install -y epel-release
      ALLOW_ERASE="--allowerasing"
  else
      yum --enablerepo=extras install -y epel-release
      ALLOW_ERASE=""
  fi

  ccache_deps="asciidoc docbook-dtds docbook-style-xsl libxslt"
  numpy_deps="gcc-gfortran"
  # Note: protobuf-c-{compiler,devel} on CentOS are too old to be used
  # for Caffe2. That said, we still install them to make sure the build
  # system opts to build/use protoc and libprotobuf from third-party.
  yum install -y $ALLOW_ERASE \
    $ccache_deps \
    $numpy_deps \
    autoconf \
    automake \
    bzip2 \
    cmake \
    cmake3 \
    curl \
    gcc \
    gcc-c++ \
    gflags-devel \
    git \
    glibc-devel \
    glibc-headers \
    glog-devel \
    hiredis-devel \
    libstdc++-devel \
    make \
    sudo \
    wget \
    vim

  if [[ $OS_VERSION == 9 ]]
  then
	  dnf --enablerepo=crb -y install libsndfile-devel
  else
	  yum install -y \
            opencv-devel \
	    libsndfile-devel
  fi

  # Cleanup
  yum clean all
  rm -rf /var/cache/yum
  rm -rf /var/lib/yum/yumdb
  rm -rf /var/lib/yum/history
}

ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
OS_VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"')

# Install base packages depending on the base OS
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

# Install Valgrind separately since the apt-get version is too old.
if [[ $ID == centos && $OS_VERSION == 7 ]]; then WGET_FLAG="--no-check-certificate" ; else WGET_FLAG=""; fi
mkdir valgrind_build && cd valgrind_build
VALGRIND_VERSION=3.16.1
if ! wget $WGET_FLAG http://valgrind.org/downloads/valgrind-${VALGRIND_VERSION}.tar.bz2
then
  wget $WGET_FLAG https://sourceware.org/ftp/valgrind/valgrind-${VALGRIND_VERSION}.tar.bz2
fi
tar -xjf valgrind-${VALGRIND_VERSION}.tar.bz2
cd valgrind-${VALGRIND_VERSION}
./configure --prefix=/usr/local
make -j 4
sudo make install
cd ../../
rm -rf valgrind_build
alias valgrind="/usr/local/bin/valgrind"